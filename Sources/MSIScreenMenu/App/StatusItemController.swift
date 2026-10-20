import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var openWhenReady = false
    private var supervisorExit: DispatchSourceProcess?
    private var idleObservation: AnyCancellable?
    private var supervisorStopped = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MSI Screen controls")
        item.button?.toolTip = "MSI Screen"
        item.button?.target = self
        item.button?.action = #selector(toggleControls)
        statusItem = item

        // A nonactivating panel lets the user keep typing in another app.
        // SwiftUI owns all monitor state; AppKit only owns presentation.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "MSI Screen"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: MonitorView(store: store))
        self.panel = panel
        observeSupervisor()
        if openWhenReady || CommandLine.arguments.contains("--show-controls") {
            showControls()
        } else {
            store.refresh()
        }
    }

    private func observeSupervisor() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--supervisor"), index + 1 < arguments.count,
              let pid = Int32(arguments[index + 1]), pid > 1 else { return }
        // LaunchServices owns the app process; OMP owns its supervisor. Observe
        // that specific supervisor's exit in the kernel, then finish any active
        // monitor transaction before terminating ourselves.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.supervisorStopped = true
            self?.quitWhenIdle()
        }
        supervisorExit = source
        source.resume()
        idleObservation = store.$busy.dropFirst().sink { [weak self] busy in
            if !busy {
                // @Published emits before the stored value changes.
                DispatchQueue.main.async { self?.quitWhenIdle() }
            }
        }
        if kill(pid, 0) != 0 && errno == ESRCH {
            supervisorStopped = true
            quitWhenIdle()
        }
    }

    private func quitWhenIdle() {
        if supervisorStopped && !store.busy { NSApp.terminate(nil) }
    }

    @objc private func toggleControls() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { showControls() }
    }

    private func showControls() {
        guard let panel else { return }
        if let button = statusItem?.button, let statusWindow = button.window {
            let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = statusWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: visible.maxY))
        } else {
            panel.center()
        }
        panel.orderFront(nil)
        store.refresh()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "msi-screen" && $0.host == "controls" }) {
            openWhenReady = true
            showControls()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }
}
