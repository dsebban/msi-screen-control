import MSIScreenCore

/// A presentation of selected or proposed inputs, independent of video-signal
/// detection and USB ownership. Saved machine names describe input assignments.
struct LayoutScene {
    enum Presentation: String {
        case current, draft, applying, unavailable

        var title: String {
            switch self {
            case .current: return "Current layout"
            case .draft: return "Proposed layout"
            case .applying: return "Applying layout"
            case .unavailable: return "Monitor unavailable"
            }
        }
    }

    enum Region: String, Identifiable {
        case fullScreen, left, right, main, inset
        var id: Self { self }

        var title: String {
            switch self {
            case .fullScreen: return "Full screen"
            case .left: return "Left"
            case .right: return "Right"
            case .main: return "Main picture"
            case .inset: return "Picture in picture"
            }
        }
    }

    struct Pane: Identifiable {
        let region: Region
        let input: Input
        let machine: MachineDefinition?
        // Draft PBP may contain duplicate inputs. Region identity keeps both
        // controls visible until the user fixes that invalid draft.
        var id: Region { region }
    }

    struct PIP {
        /// Raw monitor values. Rendering a corner or size requires a verified
        /// mapping; a schematic inset must not imply physical geometry.
        let size: Int
        let position: Int
    }

    let presentation: Presentation
    let panes: [Pane]
    /// Assigned inputs absent from this preview; this does not imply that their
    /// computers are connected. Empty when the monitor layout is unavailable.
    let otherAssignedMachines: [MachineDefinition]
    let pip: PIP?

    init(current: Bool, observed: ScreenState?, pendingTarget: ScreenState?,
         split: Bool, left: Input, right: Input, machines: [MachineDefinition]) {
        let layout: ScreenState
        if let pendingTarget {
            presentation = .applying
            layout = pendingTarget
        } else if let observed {
            let matchesObserved = observed.mode == (split ? .pbp : .off)
                && observed.source1 == left && (!split || observed.source2 == right)
            presentation = current || matchesObserved ? .current : .draft
            layout = observed
        } else {
            presentation = .unavailable
            panes = []
            otherAssignedMachines = []
            pip = nil
            return
        }

        let regions: [(Region, Input)]
        if presentation == .draft {
            regions = split ? [(.left, left), (.right, right)] : [(.fullScreen, left)]
            pip = nil
        } else {
            switch layout.mode {
            case .off:
                regions = [(.fullScreen, layout.source1)]
                pip = nil
            case .pbp:
                regions = [(.left, layout.source1), (.right, layout.source2)]
                pip = nil
            case .pip:
                regions = [(.main, layout.source1), (.inset, layout.pipInput)]
                pip = PIP(size: layout.pipSize, position: layout.pipPosition)
            }
        }

        panes = regions.map { region, input in
            let assigned = machines.filter { $0.input == input }
            return Pane(region: region, input: input, machine: assigned.count == 1 ? assigned[0] : nil)
        }
        let shown = Set(regions.map { $0.1 })
        otherAssignedMachines = machines.filter { machine in
            machine.input.map { !shown.contains($0) } ?? false
        }
    }

    /// A whole-hub destination, never a statement about current USB ownership.
    /// Video visibility and network reachability do not grant this capability.
    static func usbRoute(for machine: MachineDefinition, upstreamMachineID: String?) -> KVMRoute? {
        if machine.isLocal, machine.platform == .macos, machine.input == .usbc { return .usbc }
        if machine.isUSBUpstreamCandidate, machine.id == upstreamMachineID { return .upstream }
        return nil
    }
}
