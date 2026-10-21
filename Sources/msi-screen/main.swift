import AppKit
import Foundation
import MSIScreenCore

func emit<T: Encodable>(_ object: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(object), as: UTF8.self))
}

let help = """
msi-screen status
msi-screen identity
msi-screen pbp on [--left hdmi1|hdmi2|dp|usbc] [--right hdmi1|hdmi2|dp|usbc] [--preserve-usb] [--dry-run]
msi-screen pbp off [--preserve-usb] [--dry-run]
msi-screen input hdmi1|hdmi2|dp|usbc [--preserve-usb] [--dry-run]
msi-screen fullscreen hdmi1|hdmi2|dp|usbc [--preserve-usb] [--dry-run]
msi-screen displays
msi-screen permissions
msi-screen main monitor|built-in [--dry-run]
msi-screen arrange left|right [--dry-run]
msi-screen display-request
msi-screen capabilities
msi-screen settings
msi-screen kvm status [--machine ID]
msi-screen kvm layout [--machine ID]
msi-screen kvm set upstream|usbc --expected auto|upstream|usbc [--machine ID] [--dry-run]
msi-screen peripherals [--machine ID]
msi-screen peripherals describe
msi-screen peripherals mouse
msi-screen peripherals controllers
msi-screen peripherals controller-test [--seconds 1..15]
msi-screen peripherals mouse-map horizontal|app-switch --expected-left HEX --expected-right HEX [--dry-run]
msi-screen peripherals app-switch
msi-screen peripherals wheel-action applications|spaces
msi-screen peripherals pin-app BUNDLE_ID --expected HEX [--dry-run]
msi-screen peripherals mouse-button dpi-cycle --expected HEX [--dry-run]
msi-screen peripherals probe [--seconds 1..15]
msi-screen peripherals keyboard --slot N [--machine ID]
msi-screen set SETTING VALUE [--dry-run]
msi-screen machine list
msi-screen machine status ID
msi-screen machine arrange ID left|right [--dry-run]
msi-screen machine add ID --name NAME --platform macos|linux --input INPUT [--host SSH_ALIAS | --local] [--dry-run]
msi-screen machine update ID [--name NAME] [--platform macos|linux] [--input INPUT] [--host SSH_ALIAS | --local] [--dry-run]
msi-screen machine remove ID [--dry-run]
msi-screen machine fullscreen|pbp-left|pbp-right ID [--dry-run]
msi-screen machine focus ID [--expected-usb auto|upstream|usbc] [--dry-run]

JSON output. PBP source1 is the left side; source2 is the right side.
To swap sides, specify the two inputs in the opposite order.
Repeating the same desired configuration performs no further writes.
Only MSI MD342CQP / protocol V20 is supported. Firmware is never flashed.
identity reads two model/firmware identifiers without reading or changing model-specific settings.
It reports unmatched identities for compatibility research; shared USB IDs do not imply support.
fullscreen exits PBP/PIP and selects the input in one verified operation.
--preserve-usb reads the current USB owner's layout and preserves its USB route after a picture change.
It may temporarily acquire USB-C, then return USB after verified video readback; failures report completed stages.
Use it for picture controls while USB belongs to the configured Linux host. Auto USB changes are not supported.
Its JSON includes USB handoffs and video verification; --dry-run performs no writes.
kvm status discovers the controller locally or on the Linux USB-B machine.
kvm set sends one explicit USB route change, then verifies fresh readback; Auto is read-only.
kvm layout reads the full picture state from the current USB host.
peripherals inspects receivers on the current USB host, without changing pairings.
controllers reads this Mac's connected controller profiles, mappings and reported capabilities.
controller-test observes native gamepad input for a bounded duration; Bluetooth does not follow KVM.
mouse-map requires both current four-byte side-wheel records; apply uses the running MSI Screen app.
app-switch reads configured and active wheel actions, app activations and posted Space shortcut counts.
wheel-action changes this Mac's F18/F19 handler without reading or writing the mouse.
Space shortcut counts do not confirm that macOS changed Spaces.
pin-app maps the top DPI button to F20 after the app reserves it for an installed application.
mouse-button dpi-cycle restores the top button's verified native DPI-cycle mapping.
Both require its current four-byte record. Pin status is included in peripherals app-switch.
machine focus combines full screen with USB for the local USB-C Mac or Linux USB-B host.
machine fullscreen remains video-only. Focus failures report completed stages; do not blindly retry.
displays and main configure this Mac's desktop roles without USB access.
permissions checks the running MSI Screen app's actual TCC grants and signing identity.
arrange places the MacBook left/right of MSI, top-aligned, preserving Main/Extended.
Universal Control's order between Macs is set in macOS Displays > Arrange.
display-request accepts one schemaVersion 1 JSON request on stdin (at most 64 KiB).
Status request: {"schemaVersion":1,"action":"status"}
Main request requires action "main", target "monitor" or "built-in", and expected display state.
Machine routes use the saved input assignment; moving the opposite PBP input swaps the two sides.
Machine configuration is shared with the app. MSI_SCREEN_MACHINE_CONFIG overrides its path for isolated checks.
"""

struct Result: Encodable {
    let schemaVersion = 1
    let dryRun: Bool
    let before: ScreenState
    let changes: [Change]
    let after: ScreenState?
    let verified: Bool
}

struct SettingCapability: Encodable {
    let name: String
    let title: String
    let minimum: Int
    let maximum: Int
    let options: [Int: String]
}

struct MachineRegistryResult: Encodable {
    let schemaVersion = 1
    let dryRun: Bool
    let before: MachineRegistry
    let after: MachineRegistry
    let verified: Bool
}

struct MachineRouteResult: Encodable {
    let schemaVersion = 1
    let machineID: String
    let route: MachineRoute
    let dryRun: Bool
    let before: ScreenState
    let target: ScreenState
    let changes: [Change]
    let after: ScreenState?
    let verified: Bool
}

func machineRegistryStore() throws -> MachineRegistryStore {
    if let path = ProcessInfo.processInfo.environment["MSI_SCREEN_MACHINE_CONFIG"] {
        guard path.hasPrefix("/") else {
            throw ScreenError.message("MSI_SCREEN_MACHINE_CONFIG must be an absolute file path")
        }
        return MachineRegistryStore(url: URL(fileURLWithPath: path))
    }
    return MachineRegistryStore()
}

if let status = await dispatchInternalSupportMode(Array(CommandLine.arguments.dropFirst())) { exit(status) }

var before: ScreenState?
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] { print(help); exit(0) }
    let dryRun = args.contains("--dry-run")
    args.removeAll(where: { $0 == "--dry-run" })
    let preserveUSBCount = args.filter { $0 == "--preserve-usb" }.count
    let preserveUSB = preserveUSBCount == 1
    guard preserveUSBCount <= 1 else { throw ScreenError.message("--preserve-usb may be specified only once") }
    args.removeAll(where: { $0 == "--preserve-usb" })
    if preserveUSB, !["pbp", "fullscreen", "input"].contains(args.first ?? "") {
        throw ScreenError.message("--preserve-usb is for pbp, fullscreen, or input only")
    }
    if args == ["capabilities"], !dryRun {
        struct Capabilities: Encodable {
            let schemaVersion = 1
            let model = "MD342CQP"
            let protocolVersion = "V20"
            let inputs = Input.allCases
            let commands = ["status", "identity", "pbp on [--left INPUT] [--right INPUT]", "pbp off", "input INPUT", "fullscreen INPUT",
                            "displays", "permissions", "main monitor|built-in", "arrange left|right", "machine arrange ID left|right", "display-request", "settings", "kvm status [--machine ID]", "kvm layout [--machine ID]", "kvm set ROUTE --expected ROUTE [--machine ID]", "peripherals [--machine ID]",
                            "peripherals describe", "peripherals mouse", "peripherals mouse-map PRESET --expected-left HEX --expected-right HEX",
                            "peripherals controllers", "peripherals controller-test [--seconds 1..15]",
                            "peripherals app-switch", "peripherals wheel-action applications|spaces",
                            "peripherals pin-app BUNDLE_ID --expected HEX", "peripherals mouse-button dpi-cycle --expected HEX",
                            "peripherals probe [--seconds 1..15]", "peripherals keyboard --slot N [--machine ID]", "set SETTING VALUE",
                            "machine list", "machine status ID", "machine add ID", "machine update ID", "machine remove ID",
                            "machine fullscreen ID", "machine pbp-left ID", "machine pbp-right ID", "machine focus ID"]
            let kvmRoutes = KVMRoute.allCases
            let kvmAccess = "read-write"
            let kvmWritableRoutes: [KVMRoute] = [.upstream, .usbc]
            let machinePlatforms = ["macos", "linux"]
            let machineRoutes = ["fullscreen", "pbp-left", "pbp-right"]
            let settings = MonitorSetting.allCases.map { setting in
                SettingCapability(name: setting.rawValue, title: setting.title,
                                  minimum: setting.range.lowerBound, maximum: setting.range.upperBound,
                                  options: setting.options)
            }
            let dryRun = true
            let preserveUSBCommands = ["pbp on", "pbp off", "fullscreen INPUT", "input INPUT"]
            let mutationVerification = "Full state readback after settling"
            let typicalMutationSeconds = "5; up to 10 for cold USB-C initialization"
            let displayRequestSchemaVersion = 1
            let displayRequestMaxBytes = 65536
        }
        try emit(Capabilities())
        exit(0)
    }
    if args == ["identity"], !dryRun {
        try emit(ScreenController.withHIDConnection { try $0.identity() })
        exit(0)
    }
    if args.first == "machine" {
        guard args.count >= 2 else { throw ScreenError.message("Invalid machine command. Run msi-screen --help") }
        let action = args[1]
        if action == "list" {
            guard args.count == 2, !dryRun else {
                throw ScreenError.message("Use machine list without extra arguments")
            }
            try emit(machineRegistryStore().load())
        } else if action == "status" {
            guard args.count == 3, !dryRun else {
                throw ScreenError.message("Machine status requires an ID and accepts no --dry-run")
            }
            let registry = try machineRegistryStore().load()
            let machine = try registry.machine(id: args[2])
            let status = await MachineStatusClient().state(for: machine)
            try emit(status)
            if status.error != nil { exit(1) }
        } else if action == "arrange" {
            guard args.count == 4, let position = MacLaptopPosition(rawValue: args[3]) else {
                throw ScreenError.message("Use machine arrange ID left|right [--dry-run]")
            }
            let store = try machineRegistryStore()
            let registry = try store.load()
            let machine = try registry.machine(id: args[2])
            guard machine.platform == .macos else {
                throw ScreenError.message("MacBook arrangement requires a Mac")
            }
            let state: MacDisplayState
            if let host = machine.host { state = try await RemoteMacClient(host: host).state() }
            else { state = try MacDisplayController().state() }
            let plan = try MacDisplayController.planArrangement(from: state, laptopPosition: position)
            guard try store.load() == registry else {
                throw ScreenError.message("Machine assignments changed since planning; read the machine list again")
            }
            if dryRun { try emit(plan) }
            else if let host = machine.host {
                try emit(await RemoteMacClient(host: host).arrange(from: state, laptopPosition: position))
            } else {
                try emit(MacDisplayController().arrange(from: state, laptopPosition: position))
            }
        } else if action == "focus" {
            guard args.count == 3 || (args.count == 5 && args[3] == "--expected-usb") else {
                throw ScreenError.message("Use machine focus ID [--expected-usb ROUTE] [--dry-run]")
            }
            let expectedUSB = args.count == 5 ? KVMRoute(rawValue: args[4]) : nil
            guard args.count == 3 || expectedUSB != nil else {
                throw ScreenError.message("Expected USB route must be auto, upstream, or usbc")
            }
            let store = try machineRegistryStore()
            let coordinator = try MachineFocusCoordinator(registry: store.load(), registryStore: store)
            let result = try await coordinator.focus(machineID: args[2], expectedUSB: expectedUSB, dryRun: dryRun)
            try emit(result)
            if !dryRun && !result.verified { exit(1) }
        } else if let route = MachineRoute(rawValue: action) {
            guard args.count == 3 else {
                throw ScreenError.message("Machine routing requires exactly one machine ID")
            }
            let store = try machineRegistryStore()
            let registry = try store.load()
            guard let machine = registry.machines.first(where: { $0.id == args[2] }) else {
                throw ScreenError.message("Machine ID not found")
            }
            let result = try ScreenController.withHIDConnection { controller in
                let snapshot = try controller.state()
                before = snapshot
                let target = try MachineRouter.target(for: machine, route: route, from: snapshot)
                guard try store.load() == registry else {
                    throw ScreenError.message("Machine assignments changed since planning; read the machine list again")
                }
                let changes = ScreenController.changes(from: snapshot, to: target)
                let after = dryRun ? nil : try controller.apply(target, from: snapshot)
                return MachineRouteResult(machineID: machine.id, route: route, dryRun: dryRun,
                                          before: snapshot, target: target, changes: changes,
                                          after: after, verified: !dryRun)
            }
            try emit(result)
        } else if ["add", "update", "remove"].contains(action) {
            guard args.count >= 3, !args[2].isEmpty, !args[2].hasPrefix("-") else {
                throw ScreenError.message("Machine edit requires an ID")
            }
            let id = args[2]
            var fields: [String: String] = [:]
            var local = false
            var index = 3
            while index < args.count {
                let flag = args[index]
                if flag == "--local" {
                    guard !local, fields["--host"] == nil else {
                        throw ScreenError.message("Use --host or --local once")
                    }
                    local = true
                    index += 1
                } else {
                    guard ["--name", "--platform", "--input", "--host"].contains(flag),
                          fields[flag] == nil, index + 1 < args.count else {
                        throw ScreenError.message("Unknown, repeated, or incomplete machine option")
                    }
                    guard flag != "--host" || !local else {
                        throw ScreenError.message("Use --host or --local once")
                    }
                    fields[flag] = args[index + 1]
                    index += 2
                }
            }
            guard action != "remove" || (fields.isEmpty && !local) else {
                throw ScreenError.message("Machine remove accepts only an ID")
            }
            guard action != "update" || !fields.isEmpty || local else {
                throw ScreenError.message("Machine update requires at least one changed field")
            }
            if let platform = fields["--platform"], MachinePlatform(rawValue: platform) == nil {
                throw ScreenError.message("Machine platform must be macos or linux")
            }
            if let input = fields["--input"], Input(rawValue: input) == nil {
                throw ScreenError.message("Machine input must be hdmi1, hdmi2, dp, or usbc")
            }
            let store = try machineRegistryStore()
            let previous = try store.load()
            var updated = previous
            let existing = previous.machines.first(where: { $0.id == id })
            if action == "remove" {
                guard existing != nil else { throw ScreenError.message("Machine ID not found") }
                updated.machines.removeAll(where: { $0.id == id })
            } else {
                if action == "add" {
                    guard existing == nil else { throw ScreenError.message("Machine ID already exists; use update") }
                } else {
                    guard existing != nil else { throw ScreenError.message("Machine ID not found") }
                }
                guard let name = fields["--name"] ?? existing?.name,
                      let platform = fields["--platform"].flatMap(MachinePlatform.init(rawValue:)) ?? existing?.platform,
                      let input = fields["--input"].flatMap(Input.init(rawValue:)) ?? existing?.input else {
                    throw ScreenError.message("Machine add requires --name, --platform, and --input")
                }
                let machine = MachineDefinition(id: id, name: name, platform: platform, input: input,
                                                host: local ? nil : fields["--host"] ?? existing?.host)
                if let position = updated.machines.firstIndex(where: { $0.id == id }) {
                    updated.machines[position] = machine
                } else {
                    updated.machines.append(machine)
                }
            }
            try updated.validate()
            if !dryRun {
                try store.save(updated, replacing: previous)
                guard try store.load() == updated else {
                    throw ScreenError.message("Machine configuration did not persist; read the machine list again")
                }
            }
            try emit(MachineRegistryResult(dryRun: dryRun, before: previous, after: updated, verified: !dryRun))
        } else {
            throw ScreenError.message("Invalid machine command. Run msi-screen --help")
        }
        exit(0)
    }
    if args.starts(with: ["peripherals", "controllers"]) {
        guard !dryRun, args.count == 2 else { throw ScreenError.message("Use peripherals controllers") }
        try emit(await GameControllerClient.read())
        exit(0)
    }
    if args.starts(with: ["peripherals", "controller-test"]) {
        guard !dryRun, args.count == 2 || (args.count == 4 && args[2] == "--seconds"),
              let seconds = args.count == 2 ? 10 : Int(args[3]), (1...15).contains(seconds) else {
            throw ScreenError.message("Use peripherals controller-test [--seconds 1..15]")
        }
        try emit(await GameControllerClient.probe(seconds: seconds))
        exit(0)
    }
    if args.starts(with: ["peripherals", "pin-app"]) || args.starts(with: ["peripherals", "mouse-button"]) {
        let pin = args[1] == "pin-app"
        let usage = pin ? "Use peripherals pin-app BUNDLE_ID --expected HEX [--dry-run]"
            : "Use peripherals mouse-button dpi-cycle --expected HEX [--dry-run]"
        guard args.count == 5, args[3] == "--expected",
              args[4].range(of: "^[0-9a-fA-F]{8}$", options: .regularExpression) != nil else {
            throw ScreenError.message(usage)
        }
        let bundleIdentifier: String?
        if pin {
            guard args[2].utf8.count <= 255,
                  args[2].range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
                throw ScreenError.message(usage + "; BUNDLE_ID must identify an installed app")
            }
            bundleIdentifier = args[2]
            if dryRun {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: args[2]),
                      Bundle(url: url)?.bundleIdentifier == args[2] else {
                    throw ScreenError.message("The app \(args[2]) is not installed on this Mac.")
                }
            }
        } else {
            guard args[2] == "dpi-cycle" else { throw ScreenError.message(usage) }
            bundleIdentifier = nil
        }
        let preset: RapooTopButtonPreset = pin ? .pinnedApp : .dpiCycle
        let expectedRecordHex = args[4].lowercased()
        let result: RapooButtonChangeResult
        if dryRun {
            result = try await RapooPeripheralClient().setTopButtonPreset(preset,
                expectedRecordHex: expectedRecordHex, dryRun: true)
        } else {
            result = try await RapooAppControlClient().setTopButton(preset: preset,
                expectedRecordHex: expectedRecordHex, bundleIdentifier: bundleIdentifier)
        }
        try emit(result)
        if !dryRun && !result.verified { exit(1) }
        exit(0)
    }
    if args.starts(with: ["peripherals", "wheel-action"]) {
        guard !dryRun, args.count == 3, let action = RapooWheelHostAction(rawValue: args[2]) else {
            throw ScreenError.message("Use peripherals wheel-action applications|spaces (the MSI Screen app must be running)")
        }
        try emit(await RapooAppControlClient().setHostAction(action))
        exit(0)
    }
    if args.starts(with: ["peripherals", "app-switch"]) {
        guard !dryRun, args.count == 2 else {
            throw ScreenError.message("Use peripherals app-switch (the MSI Screen app must be running)")
        }
        try emit(await RapooAppControlClient().status())
        exit(0)
    }
    if args.starts(with: ["peripherals", "mouse-map"]) {
        let usage = "Use peripherals mouse-map horizontal|app-switch --expected-left HEX --expected-right HEX [--dry-run]"
        guard args.count == 7, let preset = ["horizontal": RapooSideWheelPreset.horizontal,
                                            "app-switch": .appSwitch][args[2]] else {
            throw ScreenError.message(usage)
        }
        var expectedHex: [String: String] = [:]
        for index in stride(from: 3, to: 7, by: 2) {
            let key = args[index], value = args[index + 1]
            guard ["--expected-left", "--expected-right"].contains(key), expectedHex[key] == nil,
                  value.range(of: "^[0-9a-fA-F]{8}$", options: .regularExpression) != nil else {
                throw ScreenError.message(usage + "; each HEX must contain exactly four bytes")
            }
            expectedHex[key] = value.lowercased()
        }
        let details = try await RapooPeripheralClient().localDetails()
        let expected = details.sideWheelMappings.sorted { $0.keyID < $1.keyID }
        guard details.errors.isEmpty, expected.map(\.keyID) == [7, 8] else {
            throw ScreenError.message("Could not read both current side-wheel records; inspect peripherals mouse")
        }
        guard expected[0].rawRecordHex.lowercased() == expectedHex["--expected-left"],
              expected[1].rawRecordHex.lowercased() == expectedHex["--expected-right"] else {
            throw ScreenError.message("Side-wheel mappings changed; read peripherals mouse before choosing expected records")
        }
        let result: RapooWheelChangeResult
        if dryRun {
            result = try await RapooPeripheralClient().setSideWheelPreset(preset, expected: expected, dryRun: true)
        } else {
            result = try await RapooAppControlClient().setSideWheel(preset: preset, expected: expected)
        }
        try emit(result)
        if !dryRun && !result.verified { exit(1) }
        exit(0)
    }
    if args.starts(with: ["peripherals", "mouse"]) {
        guard !dryRun, args.count == 2 else {
            throw ScreenError.message("Use peripherals mouse (this Mac only)")
        }
        try emit(await RapooPeripheralClient().localDetails())
        exit(0)
    }
    if args.starts(with: ["peripherals", "describe"]) {
        guard !dryRun, args.count == 2 else {
            throw ScreenError.message("Use peripherals describe (this Mac only)")
        }
        try emit(await PointerProbeClient().describe())
        exit(0)
    }
    if args.starts(with: ["peripherals", "probe"]) {
        guard !dryRun, args.count == 2 || (args.count == 4 && args[2] == "--seconds"),
              let seconds = Int(args.count == 4 ? args[3] : "10"), (1...15).contains(seconds) else {
            throw ScreenError.message("Use peripherals probe [--seconds 1..15] (this Mac only)")
        }
        let result = try await PointerProbeClient().probe(seconds: seconds)
        try emit(result)
        if !result.completed { exit(1) }
        exit(0)
    }
    if args.starts(with: ["peripherals", "keyboard"]) {
        guard !dryRun, args.count == 4 || (args.count == 6 && args[4] == "--machine"),
              args[2] == "--slot", let slot = Int(args[3]), (1...6).contains(slot) else {
            throw ScreenError.message("Use peripherals keyboard --slot 1..6 [--machine ID]")
        }
        let store = try machineRegistryStore()
        let registry = try store.load()
        let coordinator = try KVMCoordinator(registry: registry,
            upstreamMachineID: args.count == 6 ? args[5] : nil, registryStore: store)
        let owner = try await coordinator.status()
        let client = USBPeripheralClient()
        let host = try owner.machineID.flatMap { try registry.machine(id: $0).host }
        let snapshot: USBPeripheralSnapshot
        if owner.controlHost == .local { snapshot = try await client.local() }
        else if let host { snapshot = try await client.remote(host: host) }
        else { throw ScreenError.message("The USB host has no SSH connection") }
        guard let paired = snapshot.receivers.first(where: { $0.id == .bolt })?
            .pairedDevices.first(where: { $0.slot == slot }) else {
            throw ScreenError.message("No pairing metadata for that receiver slot; refresh peripherals")
        }
        let details: POPKeyboardDetails
        if owner.controlHost == .local { details = try await client.localDetails(for: paired) }
        else { details = try await client.remoteDetails(host: host!, for: paired) }
        guard try store.load() == registry, try await coordinator.status() == owner else {
            throw ScreenError.message("USB ownership or machine assignments changed during inspection")
        }
        try emit(details)
        exit(0)
    }
    if args.first == "peripherals" {
        guard !dryRun, args.count == 1 || (args.count == 3 && args[1] == "--machine") else {
            throw ScreenError.message("Use peripherals [--machine ID]")
        }
        let store = try machineRegistryStore()
        let registry = try store.load()
        let coordinator = try KVMCoordinator(registry: registry,
            upstreamMachineID: args.count == 3 ? args[2] : nil, registryStore: store)
        let owner = try await coordinator.status()
        let snapshot: USBPeripheralSnapshot
        if owner.controlHost == .local {
            snapshot = try await USBPeripheralClient().local()
        } else {
            guard let id = owner.machineID, let host = try registry.machine(id: id).host else {
                throw ScreenError.message("The USB host has no SSH connection")
            }
            snapshot = try await USBPeripheralClient().remote(host: host)
        }
        guard try store.load() == registry, snapshot.monitorHubPresent else {
            throw ScreenError.message("USB ownership or machine assignments changed during inspection; read them again")
        }
        try emit(snapshot)
        exit(0)
    }
    if args.first == "kvm" {
        guard args.count >= 2, ["status", "layout", "set"].contains(args[1]) else {
            throw ScreenError.message("Use kvm status, kvm layout, or kvm set upstream|usbc --expected ROUTE")
        }
        let action = args[1]
        var target: KVMRoute?
        var index = 2
        if action == "set" {
            guard args.count > 2, let route = KVMRoute(rawValue: args[2]), route != .auto else {
                throw ScreenError.message("KVM target must be upstream or usbc; Auto is read-only")
            }
            target = route
            index = 3
        }
        var options: [String: String] = [:]
        while index < args.count {
            let flag = args[index]
            guard ["--machine", "--expected"].contains(flag), options[flag] == nil,
                  index + 1 < args.count else { throw ScreenError.message("Unknown, repeated, or incomplete KVM option") }
            options[flag] = args[index + 1]
            index += 2
        }
        guard action == "set" || (!dryRun && options["--expected"] == nil) else {
            throw ScreenError.message("KVM reads accept only --machine ID")
        }
        let expected = options["--expected"].flatMap(KVMRoute.init(rawValue:))
        guard action != "set" || expected != nil else {
            throw ScreenError.message("KVM set requires --expected auto|upstream|usbc")
        }
        let store = try machineRegistryStore()
        let coordinator = try KVMCoordinator(registry: store.load(), upstreamMachineID: options["--machine"],
                                             registryStore: store)
        if action == "status" {
            try emit(await coordinator.status())
        } else if action == "layout" {
            try emit(await coordinator.layout())
        } else {
            let result = try await coordinator.set(target: target!, expected: expected!, dryRun: dryRun)
            try emit(result)
            if !dryRun && !result.verified { exit(1) }
        }
        exit(0)
    }
    if args == ["settings"] {
        guard !dryRun else { throw ScreenError.message("--dry-run is for setting changes") }
        let settings = try ScreenController.withHIDConnection { try $0.settings() }
        try emit(settings)
        exit(0)
    }
    if args.first == "set" {
        guard args.count == 3, let setting = MonitorSetting(rawValue: args[1]),
              let value = Int(args[2]), setting.accepts(value) else {
            throw ScreenError.message("Invalid setting or value. Run msi-screen capabilities")
        }
        struct SettingResult: Encodable {
            let dryRun: Bool
            let before: MonitorSettingsSnapshot
            let setting: MonitorSetting
            let value: Int
            let after: MonitorSettingsSnapshot?
            let verified: Bool
        }
        let result = try ScreenController.withHIDConnection { controller in
            let snapshot = try controller.settings()
            guard snapshot.value(setting) != nil, snapshot.unavailableReason(setting) == nil else {
                throw ScreenError.message(snapshot.unavailableReason(setting) ?? "Setting unavailable")
            }
            return try SettingResult(dryRun: dryRun, before: snapshot, setting: setting, value: value,
                                     after: dryRun ? nil : controller.apply(setting, value: value, from: snapshot),
                                     verified: !dryRun)
        }
        try emit(result)
        exit(0)
    }
    if args == ["permissions"] {
        guard !dryRun else { throw ScreenError.message("Use permissions without --dry-run") }
        guard let permissions = try await RapooAppControlClient().status().permissions else {
            throw ScreenError.message("Restart the updated MSI Screen app to read its permissions")
        }
        try emit(permissions)
        exit(0)
    }
    if args == ["displays"] {
        guard !dryRun else { throw ScreenError.message("--dry-run is for setting changes") }
        try emit(MacDisplayController().state())
        exit(0)
    }
    if args.count == 2, args[0] == "main", let target = MacMainDisplayTarget(rawValue: args[1]) {
        let controller = MacDisplayController()
        let state = try controller.state()
        if dryRun {
            try emit(MacDisplayController.planMain(from: state, target: target))
        } else {
            try emit(controller.makeMain(from: state, target: target))
        }
        exit(0)
    }
    if args.count == 2, args[0] == "arrange", let position = MacLaptopPosition(rawValue: args[1]) {
        let controller = MacDisplayController()
        let state = try controller.state()
        if dryRun { try emit(MacDisplayController.planArrangement(from: state, laptopPosition: position)) }
        else { try emit(controller.arrange(from: state, laptopPosition: position)) }
        exit(0)
    }
    if args == ["display-request"] {
        guard !dryRun else { throw ScreenError.message("Use main --dry-run to preview a display change") }
        let limit = 64 * 1024
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(8192, limit + 1 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw ScreenError.message("Display request exceeds 64 KiB") }
        }
        let request = try JSONDecoder().decode(MacDisplayRequest.self, from: data)
        let controller = MacDisplayController()
        switch request.action {
        case .status:
            try emit(controller.state())
        case .main:
            guard let expected = request.expected, let target = request.target else {
                throw ScreenError.message("A main display request requires expected state and target")
            }
            try emit(controller.makeMain(from: expected, target: target))
        case .arrange:
            guard let expected = request.expected, let position = request.laptopPosition else {
                throw ScreenError.message("An arrange request requires expected state and laptopPosition")
            }
            try emit(controller.arrange(from: expected, laptopPosition: position))
        }
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

    if case .status = request {
        let state = try ScreenController.withHIDConnection { try $0.state() }
        before = state
        try emit(state)
        exit(0)
    }
    func desiredLayout(from state: ScreenState) throws -> ScreenState {
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
        return target
    }
    if preserveUSB {
        let registryStore = try machineRegistryStore()
        let registry = try registryStore.load()
        let kvm = try KVMCoordinator(registry: registry, registryStore: registryStore)
        let usb = try await kvm.status()
        let state = try await kvm.layout()
        before = state
        let target = try desiredLayout(from: state)
        let coordinator = try LayoutCoordinator(registry: registry, registryStore: registryStore)
        let result = try await coordinator.apply(target, from: state, expectedUSB: usb.route, dryRun: dryRun)
        try emit(result)
        if !dryRun && !result.verified { exit(1) }
        exit(0)
    }
    let result = try ScreenController.withHIDConnection { controller in
        let state = try controller.state()
        before = state
        let target = try desiredLayout(from: state)
        let changes = ScreenController.changes(from: state, to: target)
        let after = dryRun ? nil : try controller.apply(target, from: state)
        return Result(dryRun: dryRun, before: state, changes: changes, after: after, verified: !dryRun)
    }
    try emit(result)
} catch {
    struct Failure: Encodable {
        let error: String
        let before: ScreenState?
        let verified = false
    }
    try? emit(Failure(error: String(describing: error), before: before))
    exit(1)
}
