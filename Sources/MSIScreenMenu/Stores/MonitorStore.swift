import Foundation
import MSIScreenCore

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var state: ScreenState?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var message = "Connect the monitor’s USB upstream cable."
    @Published var split = false
    @Published var left: Input = .dp
    @Published var right: Input = .usbc

    private let queue = DispatchQueue(label: "MSIScreen.usb", qos: .userInitiated)

    var target: ScreenState? {
        guard let state else { return nil }
        if split {
            return try? ScreenController.pbpTarget(from: state, enabled: true, left: left, right: right)
        }
        return ScreenController.fullscreenTarget(from: state, input: left)
    }

    var canApply: Bool { !busy && target != nil && target != state }
    var duplicateInputs: Bool { split && left == right }
    var currentLayout: String? {
        guard let state else { return nil }
        switch state.mode {
        case .off: return "Current: \(state.source1.title) full screen"
        case .pbp: return "Current: \(state.source1.title) | \(state.source2.title)"
        case .pip: return "Current: picture in picture"
        }
    }
    var command: String {
        split ? "msi-screen pbp on --left \(left.rawValue) --right \(right.rawValue)"
              : "msi-screen fullscreen \(left.rawValue)"
    }

    func refresh() {
        perform(message: "Reading monitor…") { controller in try controller.state() }
    }

    func swap() {
        let previousLeft = left
        left = right
        right = previousLeft
    }

    func apply() {
        guard let before = state, let target, canApply else { return }
        // Carry the displayed baseline across the UI boundary. A newer OSD or
        // CLI change must fail the core's comparison, not get overwritten.
        perform(message: "Applying · allow 5–10 seconds…") { controller in
            try controller.apply(target, from: before)
        }
    }

    private func perform(message: String, operation: @escaping (ScreenController) throws -> ScreenState) {
        guard !busy else { return }
        busy = true
        error = nil
        self.message = message
        queue.async {
            // Each operation owns one synchronous HID session. Creation, I/O
            // and destruction stay on this thread and its CFRunLoop. Releasing
            // it before returning also frees the interprocess lock for the CLI.
            let result: Result<ScreenState, Error> = Result {
                let controller = ScreenController(transport: try HIDConnection())
                return try operation(controller)
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let state):
                    self.state = state
                    self.split = state.mode == .pbp
                    self.left = state.source1
                    self.right = state.source2
                    self.message = state.mode == .pip ? "PIP active · choose a layout to replace it." : "Read back from monitor"
                case .failure(let error):
                    self.state = nil
                    self.error = String(describing: error)
                    self.message = "Refresh before trying again."
                }
            }
        }
    }
}

extension Input {
    var title: String {
        switch self {
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .dp: return "DisplayPort"
        case .usbc: return "USB-C"
        }
    }
}
