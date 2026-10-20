import MSIScreenCore

/// The Layout tab and its copied CLI command must describe the same operation.
struct LayoutApplication {
    let target: ScreenState
    let focusMachine: MachineDefinition?

    init(target: ScreenState, machines: [MachineDefinition], followUSB: Bool) {
        self.target = target
        let assigned = machines.filter { $0.input == target.source1 }
        if followUSB, target.mode == .off, assigned.count == 1,
           let machine = assigned.first,
           (machine.isLocal && machine.input == .usbc) || machine.platform == .linux {
            focusMachine = machine
        } else {
            focusMachine = nil
        }
    }

    func canApply(from current: ScreenState, kvm: KVMStatus?, localReadBlocked: Bool) -> Bool {
        guard let machine = focusMachine else {
            return target != current && (!localReadBlocked || kvm != nil)
        }
        // A matching picture can still need a USB handoff. Never silently fall
        // back to video-only when the current USB host has not been read.
        guard let kvm else { return false }
        let usb: KVMRoute = machine.isLocal ? .usbc : .upstream
        let host: KVMControlHost = machine.isLocal ? .local : .upstream
        return target != current || kvm.route != usb || kvm.controlHost != host
    }

    var command: String {
        if let machine = focusMachine { return "msi-screen machine focus \(machine.id)" }
        return target.mode == .pbp
            ? "msi-screen pbp on --left \(target.source1.rawValue) --right \(target.source2.rawValue)"
            : "msi-screen fullscreen \(target.source1.rawValue)"
    }
}
