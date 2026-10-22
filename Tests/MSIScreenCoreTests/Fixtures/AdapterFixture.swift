// Disposable process fixture, compiled by tests. Never a production adapter.
import CryptoKit
import Darwin
import Foundation

func emit(_ value: String, to fd: Int32 = STDOUT_FILENO) {
    let bytes = Array(value.utf8)
    bytes.withUnsafeBytes { pointer in
        var offset = 0
        while offset < bytes.count {
            let n = write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n <= 0 { return }; offset += n
        }
    }
}
func mark(_ path: String, _ value: String = "ready") { try! Data(value.utf8).write(to: URL(fileURLWithPath: path)) }
func nativeFixture() throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let request = try JSONSerialization.jsonObject(with: input) as! [String: Any]
    let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let configURL = path.deletingLastPathComponent().appendingPathComponent("fixture.json")
    let config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Any] ?? [:]
    let mode = config["mode"] as? String ?? "normal"
    let marker = config["marker"] as? String ?? ""
    let hash = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
    var hello: [String: Any] = ["hostAPI": 1, "buildIdentity": request["buildIdentity"]!, "requestID": request["requestID"]!,
        "providerDigest": request["providerDigest"]!, "executableDigest": hash]
    if mode == "badHello" { hello["buildIdentity"] = "wrong-build" }
    let bytes = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys]) + Data([10])
    bytes.withUnsafeBytes { _ = write(201, $0.baseAddress!, $0.count) }
    var ack: UInt8 = 0
    guard read(201, &ack, 1) == 1 && ack == 1 else { exit(65) }
    if !marker.isEmpty {
        let facts: [String: Any] = ["pid": getpid(), "parent": getppid(), "group": getpgrp(),
            "lease": fcntl(210, F_GETFD) >= 0, "sentinel": fcntl(199, F_GETFD) >= 0,
            "environment": ProcessInfo.processInfo.environment, "operation": request["operation"]!]
        let event = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        try event.write(to: URL(fileURLWithPath: marker))
        let trace = open(marker + ".events", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if trace >= 0 { (event + Data([10])).withUnsafeBytes { _ = write(trace, $0.baseAddress!, $0.count) }; close(trace) }
    }
    let deadline = request["deadlineUptimeMilliseconds"] as! Int64
    func alive() -> Bool {
        var event = pollfd(fd: 200, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        return poll(&event, 1, 0) == 0 && Int64(ProcessInfo.processInfo.systemUptime * 1000) < deadline
    }
    if mode == "killSupervisor" { kill(getppid(), SIGKILL) }
    if ["hold", "killSupervisor", "noise"].contains(mode) {
        while alive() { if mode == "noise" { emit(String(repeating: "x", count: 4096)) }; usleep(1000) }
        if !marker.isEmpty { mark(marker + ".eof", "liveness-or-deadline") }; exit(0)
    }
    if mode == "descendant" {
        precondition(!marker.isEmpty)
        let childMarker = marker + ".descendant"
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        precondition(posix_spawn_file_actions_init(&actions) == 0 && posix_spawnattr_init(&attributes) == 0)
        precondition(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        for fd: Int32 in [0, 1, 2] { precondition(posix_spawn_file_actions_addinherit_np(&actions, fd) == 0) }
        let childArguments: [String] = [path.path, "hold", childMarker]
        let strings = childArguments.map { strdup($0)! }
        var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [nil]; var child: pid_t = 0
        precondition(posix_spawn(&child, path.path, &actions, &attributes, &argv, &env) == 0)
        for string in strings { free(string) }; posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
        while !FileManager.default.fileExists(atPath: childMarker) && alive() { usleep(1000) }
    }
    if mode == "privateDiagnostic" { emit("PRIVATE_USER /Users/private/secret SERIAL-PRIVATE", to: STDERR_FILENO); exit(17) }
    if mode == "nonzero" { exit(17) }
    if mode == "malformed" { emit("{bad"); exit(0) }
    if mode == "mutate" { try Data("changed".utf8).write(to: configURL) }
    let payload = request["payload"] as! [String: Any]
    let operation = request["operation"] as! String
    var result: [String: Any] = ["kind": operation]
    let stateURL = URL(fileURLWithPath: config["statePath"] as? String ?? "")
    func telemetry(_ state: inout [String: Any], phase: String) throws {
        let selected = mode == "telemetry" || ["telemetryGuard", "telemetryPreservation", "telemetryEffect", "telemetryIndependentGuard"].contains(mode)
            || (mode == "telemetryBefore" && phase == "before") || (mode == "telemetryAfter" && phase == "after")
            || (mode == "telemetryPostRead" && phase == "read" && FileManager.default.fileExists(atPath: marker + ".writes"))
        guard selected else { return }
        let counterURL = URL(fileURLWithPath: stateURL.path + ".telemetry")
        let counter = ((try? Int(String(contentsOf: counterURL))) ?? 0) + 1
        try String(counter).write(to: counterURL, atomically: true, encoding: .utf8)
        var values = state["values"] as! [String: Any], unavailable = state["unavailable"] as! [String: Any]
        if counter % 3 == 2 { values.removeValue(forKey: "information"); unavailable["information"] = ["code": "telemetryUnavailable"] }
        else { values["information"] = ["kind": "integer", "value": counter]; unavailable.removeValue(forKey: "information") }
        state["values"] = values; state["unavailable"] = unavailable
    }
    switch operation {
    case "selfTest": precondition(payload["endpoint"] == nil && payload["expected"] == nil)
    case "plan":
        var planned = payload["operation"] as! [String: Any]
        if mode == "normalizeCoupled" {
            var target = planned["target"] as! [String: Any]
            if target["kind"] as? String == "layout" {
                var value = target["value"] as! [String: Any], options = (target["value"] as! [String: Any])["options"] as! [String: String]
                options["ratio"] = "wide"; value["options"] = options; target["value"] = value; planned["target"] = target
            }
        }
        result["operation"] = planned
    case "read":
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        try telemetry(&state, phase: "read")
        if mode == "telemetryIndependentGuard" && FileManager.default.fileExists(atPath: marker + ".writes") {
            var fields = state["fields"] as! [String: Any]; fields["guard"] = ["kind": "integer", "value": 8]; state["fields"] = fields
        }
        state["identity"] = payload["identity"]!
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        result["state"] = state
    case "apply":
        let expected = payload["expected"] as! [String: Any]
        var current = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        current["identity"] = expected["identity"]!
        try telemetry(&current, phase: "before")
        let before = current
        let canonical: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        // This fixture declares exactly one informational value. It is not a
        // configuration field, guard or preservation byte in this protocol.
        func configuration(_ state: [String: Any]) -> [String: Any] {
            var copy = state, values = state["values"] as! [String: Any], unavailable = state["unavailable"] as! [String: Any]
            values.removeValue(forKey: "information"); unavailable.removeValue(forKey: "information")
            copy["values"] = values; copy["unavailable"] = unavailable; return copy
        }
        if try canonical(configuration(current)) != canonical(configuration(expected)) {
            result = ["kind": "rejected", "failure": ["code": "staleBaseline"]]; break
        }
        guard alive() else { exit(71) }
        if let delay = config["applyDelayMilliseconds"] as? Int, (0...2000).contains(delay) {
            let end = ProcessInfo.processInfo.systemUptime + Double(delay) / 1000
            while ProcessInfo.processInfo.systemUptime < end { guard alive() else { exit(71) }; usleep(1000) }
        }
        let plan = payload["plan"] as! [String: Any], operation = plan["operation"] as! [String: Any]
        let id = operation["capabilityID"] as! String, target = operation["target"] as! [String: Any]
        var values = current["values"] as! [String: Any], fields = current["fields"] as! [String: Any]
        values[id] = target
        func choice(_ value: Any) -> [String: Any] { ["kind": "choice", "value": value] }
        switch id {
        case "level": fields["level"] = target
        case "enabled": fields["enabled"] = ["kind": "integer", "value": (target["value"] as! Bool) ? 1 : 0]
        case "layout":
            let layout = target["value"] as! [String: Any]
            fields["template"] = choice(layout["templateID"]!)
            for (slot, value) in layout["slots"] as! [String: Any] { fields[slot] = choice(value) }
            for (option, value) in layout["options"] as! [String: Any] { fields[option] = choice(value) }
        case "route": fields["route"] = choice((target["value"] as! [String: Any])["configuredDestinationID"]!)
        case "mapping": for (control, value) in target["value"] as! [String: Any] { fields[control] = choice(value) }
        default: exit(72)
        }
        if mode == "telemetryGuard" { fields["guard"] = ["kind": "integer", "value": 8] }
        if mode == "telemetryEffect" { values["enabled"] = ["kind": "boolean", "value": true] }
        current["values"] = values; current["fields"] = fields
        try telemetry(&current, phase: "after")
        if mode == "wrongPreservation" || mode == "telemetryPreservation" { current["preservation"] = ["opaque": "changed"] }
        try canonical(current).write(to: stateURL, options: .atomic)
        if !marker.isEmpty {
            let writesURL = URL(fileURLWithPath: marker + ".writes")
            var writes = (try? Data(contentsOf: writesURL)) ?? Data(); writes.append(1); try writes.write(to: writesURL)
        }
        if mode == "lostApply" { exit(73) }
        result["result"] = ["before": before, "after": current, "attempted": true, "completed": true, "acknowledged": true]
    default: exit(64)
    }
    // Negative cleanup evidence is deliberate semantic fixture data, not an
    // escaped child: exercise propagation without leaving an unsafe process.
    if mode == "cleanupFalseMutation" || mode == "cleanupFalseCorrelation" {
        result = ["kind": "failed", "failure": ["code": "cleanupFailed", "dispatched": false, "cleanupConfirmed": false]]
        if mode == "cleanupFalseMutation" { try Data("changed".utf8).write(to: configURL) }
    }
    var response: [String: Any] = ["schema": 1, "hostAPI": 1, "buildIdentity": request["buildIdentity"]!, "requestID": request["requestID"]!,
        "providerDigest": request["providerDigest"]!, "operation": operation, "result": result]
    if mode == "wrongRequest" || mode == "cleanupFalseCorrelation" { response["requestID"] = UUID().uuidString }
    if mode == "unknownKey" { response["private"] = "not-allowed" }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]))
}
let args = CommandLine.arguments
if args.count == 1 { do { try nativeFixture(); exit(0) } catch { exit(70) } }
switch args[1] {
case "runtime-parent":
    // Own the only writer and lease, then hand the same open description to a
    // real compiled profile/native worker in its own group. No Core mocks.
    var live: [Int32] = [-1,-1], hello: [Int32] = [-1,-1]
    precondition(pipe(&live) == 0 && socketpair(AF_UNIX, SOCK_STREAM, 0, &hello) == 0)
    let lease = open(args[6], O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    precondition(lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0)
    let input = open(args[3], O_RDONLY | O_CLOEXEC)
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    precondition(posix_spawn_file_actions_init(&actions) == 0 && posix_spawnattr_init(&attributes) == 0)
    precondition(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)) == 0)
    precondition(posix_spawnattr_setpgroup(&attributes, 0) == 0)
    for pair in [(input, Int32(0)), (Int32(1), Int32(1)), (Int32(2), Int32(2)), (live[0], Int32(200)), (hello[1], Int32(201)), (lease, Int32(210))] {
        precondition(posix_spawn_file_actions_adddup2(&actions, pair.0, pair.1) == 0)
    }
    let arguments = args[7] == "profile" ? [args[2], "support-worker", args[4], args[4]] : [args[2]]
    let strings = arguments.map { strdup($0)! }
    var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
    var env: [UnsafeMutablePointer<CChar>?] = [nil]; var child: pid_t = 0
    precondition(posix_spawn(&child, args[2], &actions, &attributes, &argv, &env) == 0)
    for string in strings { free(string) }; posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
    close(input); close(hello[1]); close(live[0]); close(lease) // The worker alone now holds the lease.
    var line = Data(), byte: UInt8 = 0
    while read(hello[0], &byte, 1) == 1 && byte != 10 { line.append(byte); precondition(line.count < 4096) }
    let response = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
    let request = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
    precondition(response["buildIdentity"] as? String == request["buildIdentity"] as? String)
    precondition(response["providerDigest"] as? String == request["providerDigest"] as? String)
    if args[7] == "native" { byte = 1; precondition(write(hello[0], &byte, 1) == 1) }
    mark(args[5], "\(getpid()) \(child)")
    while true { pause() }
case "streams":
    for i in 0..<40 { emit("out-\(i)\n"); emit("err-\(i)\n", to: 2) }
case "environment":
    let value: [String: Any] = ["environment": ProcessInfo.processInfo.environment, "pid": getpid(), "group": getpgrp(),
        "listed": fcntl(210, F_GETFD) >= 0, "sentinel": fcntl(200, F_GETFD) >= 0, "legacy": fcntl(201, F_GETFD) >= 0]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
case "hold":
    signal(SIGTERM, SIG_IGN); mark(args[2], String(getpid())); while true { pause() }
case "noise":
    emit("stderr-start\n", to: 2)
    let bytes = Array(String(repeating: "n", count: 4096).utf8)
    while true { bytes.withUnsafeBytes { _ = write(1, $0.baseAddress!, $0.count); _ = write(2, $0.baseAddress!, $0.count) } }
case "descendants", "parent-loss":
    var ready: [Int32] = [-1, -1]; var liveness: [Int32] = [-1, -1]
    precondition(pipe(&ready) == 0 && pipe(&liveness) == 0)
    let parentLoss = args[1] == "parent-loss"
    var actions: posix_spawn_file_actions_t?; var attributes: posix_spawnattr_t?
    precondition(posix_spawn_file_actions_init(&actions) == 0 && posix_spawnattr_init(&attributes) == 0)
    precondition(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
    for fd: Int32 in [0, 1, 2] { precondition(posix_spawn_file_actions_addinherit_np(&actions, fd) == 0) }
    precondition(posix_spawn_file_actions_adddup2(&actions, liveness[0], 212) == 0)
    precondition(posix_spawn_file_actions_adddup2(&actions, ready[1], 213) == 0)
    let childArguments: [String] = [args[0], "descendant-child", parentLoss ? "parent-loss" : "hold"]
    let strings = childArguments.map { strdup($0)! }
    var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
    var env: [UnsafeMutablePointer<CChar>?] = [nil]
    var child: pid_t = 0
    precondition(posix_spawn(&child, args[0], &actions, &attributes, &argv, &env) == 0)
    for string in strings { free(string) }
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
    close(ready[1]); close(liveness[0]); var byte: UInt8 = 0
    _ = read(ready[0], &byte, 1); close(ready[0])
    emit("descendant:\(child)\n")
    if args.count > 3 { mark(args[3], String(child)) }
    if parentLoss { kill(getpid(), SIGKILL) }
    if args[2] == "normal" { _exit(0) }
    while true { pause() }
case "descendant-child":
    signal(SIGTERM, SIG_IGN)
    var byte: UInt8 = 1; _ = write(213, &byte, 1); close(213)
    if args[2] == "parent-loss" {
        while read(212, &byte, 1) < 0 && errno == EINTR {}
        emit("parent-eof:\(getpid())\n"); usleep(150000); exit(0)
    }
    while true { pause() }
case "lease":
    precondition(fcntl(210, F_GETFD) >= 0 && fcntl(211, F_GETFD) >= 0)
    mark(args[2], String(getpid()))
    var byte: UInt8 = 0
    while read(211, &byte, 1) < 0 && errno == EINTR {}
    emit("liveness-eof\n")
case "exit": exit(Int32(args[2])!)
case "signal": raise(SIGUSR1)
default: exit(64)
}
