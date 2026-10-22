import SwiftUI
import MSIScreenCore

/// Video assignments and observed USB ownership share a picture, not state.
/// Editing a video draft must never imply that its computer already owns USB.
struct LayoutPreviewView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var prefs: MonitorPreferences
    let controlsBusy: Bool
    var compact = false

    private var scene: LayoutScene {
        LayoutScene(current: compact, observed: store.state, pendingTarget: store.pendingTarget,
                    split: store.split, left: store.left, right: store.right, machines: prefs.machines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                HStack {
                    Text("LAYOUT PREVIEW").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(presentationTitle, systemImage: presentationSymbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(presentationColor)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(presentationColor.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(presentationColor.opacity(0.35)))
                        .accessibilityIdentifier("layout-preview-status")
                }
            }
            VStack(spacing: 0) {
                screen
                    .frame(height: compact ? 68 : 166)
                    .padding(4)
                    .background(Color(red: 0.035, green: 0.04, blue: 0.065))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.44), lineWidth: 0.7))
                Rectangle().fill(.white.opacity(0.15)).frame(width: 26, height: compact ? 6 : 12)
                Capsule().fill(.white.opacity(0.27)).frame(width: compact ? 130 : 195, height: 3)
            }
            .accessibilityElement(children: compact ? .ignore : .contain)
            .accessibilityLabel(layoutSummary)
            .accessibilityIdentifier("layout-preview")

            if !compact {
                Text("Keyboard and mouse move together with the USB hub.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                if let peer = prefs.universalControlPeer, let local = prefs.localMachine {
                    HStack(spacing: 7) {
                        Image(systemName: "link").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Universal Control").font(.system(size: 11, weight: .semibold))
                            Text("\(local.name) ↔ \(peer.name)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "keyboard")
                        Image(systemName: "computermouse")
                    }
                    .font(.system(size: 11))
                    .padding(8)
                    .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .help("Configured keyboard and mouse sharing between these Macs. Managed in macOS Displays; this label does not monitor the live connection.")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("layout-universal-control-link")
                }
                if store.kvm == nil {
                    Button("Read keyboard & mouse route") { store.refreshKVM() }
                        .font(.caption).buttonStyle(.borderless)
                        .disabled(store.hasActiveOperation || controlsBusy)
                        .accessibilityIdentifier("layout-read-usb")
                }
                if scene.presentation == .draft || scene.presentation == .applying {
                    Text(scene.presentation == .applying ? "Applying this layout…" : "Draft · choose Apply layout to show these inputs.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .accessibilityIdentifier("layout-preview-draft")
                }
                if let error = store.kvmError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                otherMachines
            }
        }
    }

    @ViewBuilder private var screen: some View {
        if scene.panes.isEmpty {
            Label("Monitor unavailable", systemImage: "display.trianglebadge.exclamationmark")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scene.pip != nil, scene.panes.count == 2 {
            // The inset is schematic: raw OSD size/position codes have no
            // hardware-qualified geometry mapping in this client.
            ZStack(alignment: .bottomTrailing) {
                pane(scene.panes[0])
                pane(scene.panes[1], inset: true)
                    .frame(width: compact ? 108 : 140, height: compact ? 42 : 90)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.55)))
                    .padding(5)
            }
        } else {
            HStack(spacing: 3) {
                ForEach(scene.panes) { pane($0) }
            }
        }
    }

    private func pane(_ entry: LayoutScene.Pane, inset: Bool = false) -> some View {
        let small = compact || inset
        let tint = MonitorAppearance.tint(for: entry.input)
        return VStack(spacing: small ? 3 : 7) {
            if !small {
                Text(entry.region.title.uppercased())
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.2), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if !small {
                Image(systemName: symbol(entry.machine)).font(.system(size: 25)).foregroundStyle(tint)
            }
            Text(entry.machine?.name ?? "Unassigned input")
                .font(.system(size: small ? 11 : 16, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityIdentifier("layout-machine-\(entry.region.rawValue)")
            Text(entry.input.title).font(.system(size: small ? 9 : 11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, small ? 1 : 3)
                .background(tint.opacity(0.13), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 0.7))
            Spacer(minLength: 0)
            if !small {
                if let machine = entry.machine {
                    VStack(spacing: 3) {
                        if prefs.usesUniversalControl(machine),
                           LayoutScene.usbRoute(for: machine, upstreamMachineID: prefs.usbUpstreamMachine?.id) != nil {
                            universalControlBadge
                        }
                        peripheralControl(machine, inPane: true)
                    }
                }
                else { Text("Assign in Machines").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
        }
        .padding(small ? 6 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MonitorScreenArtwork(input: entry.input))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.region.title), \(entry.machine?.name ?? "Unassigned input"), \(entry.input.title)")
    }

    @ViewBuilder private var otherMachines: some View {
        if !scene.otherAssignedMachines.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(scene.presentation == .current && !store.needsRefresh ? "OFF SCREEN" : "OTHER INPUTS")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                    Text("\(scene.otherAssignedMachines.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.07), in: Capsule())
                }
                .foregroundStyle(.secondary).padding(.top, 4)
                ForEach(scene.otherAssignedMachines) { machine in
                    HStack(spacing: 7) {
                        Image(systemName: symbol(machine)).font(.system(size: 18))
                            .frame(width: 25).foregroundStyle(MonitorAppearance.secondaryText)
                        Text(machine.name).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(machine.input?.title ?? "")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.white.opacity(0.06), in: Capsule())
                        Spacer(minLength: 0)
                        peripheralControl(machine, inPane: false)
                    }
                    .padding(.horizontal, 9).frame(height: 39)
                    .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.09), lineWidth: 0.7))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("layout-other-\(machine.id)")
                }
            }
        }
    }

    @ViewBuilder private func peripheralControl(_ machine: MachineDefinition, inPane: Bool) -> some View {
        if let route = LayoutScene.usbRoute(for: machine, upstreamMachineID: prefs.usbUpstreamMachine?.id) {
            let selected = store.kvm?.route == route
            if selected {
                peripheralBadge(selected: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Keyboard and mouse enabled on \(machine.name)")
                    .accessibilityValue("Current USB host")
                    .help("The monitor USB hub is routed to \(machine.name). Devices must be in receiver mode.")
            } else {
                Button {
                    store.setKVM(route, expectedMachines: prefs.machines, expectedUpstreamMachineID: prefs.usbUpstreamMachine?.id)
                } label: { peripheralBadge(selected: false) }
                .buttonStyle(.plain)
                .disabled(store.hasActiveOperation || controlsBusy || prefs.error != nil || store.kvm == nil
                          || USBHostControls.configurationIssue(machines: prefs.machines, upstreamMachineID: prefs.usbUpstreamMachine?.id) != nil)
                .accessibilityLabel("Enable keyboard and mouse on \(machine.name)")
                .accessibilityIdentifier("layout-usb-\(machine.id)")
                .help("Move the entire monitor USB hub to \(machine.name). Video stays unchanged.")
            }
        } else if prefs.usesUniversalControl(machine) {
            universalControlBadge
                .accessibilityLabel("\(machine.name), keyboard and mouse via Universal Control")
        } else {
            Text("USB not assigned").font(.system(size: 9))
                .foregroundStyle(.secondary).lineLimit(1)
                .help("This computer is not assigned to either wired USB host. Bluetooth pairing and Universal Control are separate.")
        }
    }

    private var universalControlBadge: some View {
        Label("Universal Control", systemImage: "link")
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.purple)
            .lineLimit(1)
            .help("Keyboard and mouse sharing through the configured Mac-to-Mac link. USB routing stays independent.")
    }

    private func peripheralBadge(selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "keyboard")
            Image(systemName: "computermouse")
            Text(selected ? "Enabled" : "Enable").fontWeight(.medium)
        }
        .font(.system(size: 10))
        .foregroundStyle(selected ? Color.green : .white)
        .padding(.horizontal, 9).frame(height: 27)
        .background(selected ? Color.green.opacity(0.13) : .white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.green.opacity(0.5) : .white.opacity(0.2), lineWidth: 0.7))
    }

    private var presentationTitle: String {
        if store.needsRefresh && scene.presentation == .current { return "Refresh needed" }
        switch scene.presentation {
        case .current: return "Live"
        case .draft: return "Draft"
        case .applying: return "Applying"
        case .unavailable: return "Unavailable"
        }
    }
    private var presentationColor: Color { scene.presentation == .current && !store.needsRefresh ? .green : .orange }
    private var presentationSymbol: String { scene.presentation == .current && !store.needsRefresh ? "circle.fill" : "clock" }
    private func symbol(_ machine: MachineDefinition?) -> String {
        machine?.platform == .macos ? "laptopcomputer" : "desktopcomputer"
    }
    private var layoutSummary: String {
        guard !scene.panes.isEmpty else { return "Monitor unavailable. Reconnect the monitor, then refresh." }
        let inputs = scene.panes.map { "\($0.input.title) \($0.region.title.lowercased())" }.joined(separator: ", ")
        let names = scene.panes.map { $0.machine?.name ?? "Unassigned input" }.joined(separator: ", ")
        let title = store.needsRefresh && scene.presentation == .current ? "Last read layout" : scene.presentation.title
        return "\(title): \(inputs). Computers: \(names)."
    }
}
