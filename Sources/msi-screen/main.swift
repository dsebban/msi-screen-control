import Foundation
import MSIScreenCore

func emit<T: Encodable>(_ object: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(object), as: UTF8.self))
}

let help = """
msi-screen status
msi-screen pbp on [--left hdmi1|hdmi2|dp|usbc] [--right hdmi1|hdmi2|dp|usbc] [--dry-run]
msi-screen pbp off [--dry-run]
msi-screen input hdmi1|hdmi2|dp|usbc [--dry-run]
msi-screen fullscreen hdmi1|hdmi2|dp|usbc [--dry-run]
msi-screen capabilities

JSON output. PBP source1 is the left side; source2 is the right side.
To swap sides, specify the two inputs in the opposite order.
Repeating the same desired configuration performs no further writes.
Only MSI MD342CQP / protocol V20 is supported. Firmware is never flashed.
fullscreen exits PBP/PIP and selects the input in one verified operation.
"""

struct Result: Encodable {
    let schemaVersion = 1
    let dryRun: Bool
    let before: ScreenState
    let changes: [Change]
    let after: ScreenState?
    let verified: Bool
}

var before: ScreenState?
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] { print(help); exit(0) }
    let dryRun = args.contains("--dry-run")
    args.removeAll(where: { $0 == "--dry-run" })
    if args == ["capabilities"], !dryRun {
        struct Capabilities: Encodable {
            let schemaVersion = 1
            let model = "MD342CQP"
            let protocolVersion = "V20"
            let inputs = Input.allCases
            let commands = ["status", "pbp on [--left INPUT] [--right INPUT]", "pbp off", "input INPUT", "fullscreen INPUT"]
            let dryRun = true
            let mutationVerification = "Full state readback after settling"
            let typicalMutationSeconds = "5; up to 10 for cold USB-C initialization"
        }
        try emit(Capabilities())
        exit(0)
    }
    enum Request { case status, pbp(Bool, Input?, Input?), input(Input), fullscreen(Input) }
    let request: Request
    if args == ["status"] {
        guard !dryRun else { throw ScreenError.message("--dry-run is for setting changes") }
        request = .status
    } else if args.count == 2, args[0] == "input", let input = Input(rawValue: args[1]) {
        request = .input(input)
    } else if args.count == 2, args[0] == "fullscreen", let input = Input(rawValue: args[1]) {
        request = .fullscreen(input)
    } else if args.count >= 2, args[0] == "pbp", ["on", "off"].contains(args[1]) {
        var left: Input?, right: Input?
        var index = 2
        while index < args.count {
            guard index + 1 < args.count, let input = Input(rawValue: args[index + 1]) else {
                throw ScreenError.message("Expected --left/--right and an input: hdmi1, hdmi2, dp, usbc")
            }
            switch args[index] {
            case "--left" where left == nil: left = input
            case "--right" where right == nil: right = input
            default: throw ScreenError.message("Unknown or repeated option: \(args[index])")
            }
            index += 2
        }
        guard args[1] == "on" || (left == nil && right == nil) else {
            throw ScreenError.message("Use --left/--right with pbp on")
        }
        request = .pbp(args[1] == "on", left, right)
    } else { throw ScreenError.message("Invalid command. Run msi-screen --help") }

    let controller = ScreenController(transport: try HIDConnection())
    let state = try controller.state()
    before = state
    if case .status = request { try emit(state); exit(0) }
    var target = state
    switch request {
    case .status: break
    case .pbp(let on, let left, let right): target = try ScreenController.pbpTarget(from: state, enabled: on, left: left, right: right)
    case .input(let value):
        guard state.mode == .off else { throw ScreenError.message("Use pbp on --left/--right while in split mode, or pbp off first") }
        target.source1 = value
    case .fullscreen(let value):
        target = ScreenController.fullscreenTarget(from: state, input: value)
    }
    let changes = ScreenController.changes(from: state, to: target)
    let after = dryRun ? nil : try controller.apply(target, from: state)
    try emit(Result(dryRun: dryRun, before: state, changes: changes, after: after, verified: !dryRun))
} catch {
    struct Failure: Encodable {
        let error: String
        let before: ScreenState?
        let verified = false
    }
    try? emit(Failure(error: String(describing: error), before: before))
    exit(1)
}
