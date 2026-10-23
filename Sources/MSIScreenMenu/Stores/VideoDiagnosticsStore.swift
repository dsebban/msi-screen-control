import AppKit
import Combine
import MSIScreenCore

@MainActor
final class VideoDiagnosticsStore: ObservableObject {
    @Published private(set) var snapshot: VideoDiagnosticsSnapshot?
    @Published private(set) var history = VideoStabilityHistory()
    @Published private(set) var monitoring = false
    @Published private(set) var busy = false
    private var timer: AnyCancellable?
    private var displayObserver: NSObjectProtocol?
    private var generation: UInt64 = 0

    func start() {
        guard !monitoring else { return }
        generation += 1
        busy = false
        history = VideoStabilityHistory()
        monitoring = true
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer = Timer.publish(every: 2, tolerance: 0.3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        monitoring = false
        generation += 1
        busy = false
        timer = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let request = generation
        Task {
            let result = await Task.detached(priority: .utility) { VideoDiagnosticsClient().snapshot() }.value
            guard request == generation else { return }
            snapshot = result
            if monitoring { history.observe(result) }
            busy = false
        }
    }

    deinit {
        timer?.cancel()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }
}
