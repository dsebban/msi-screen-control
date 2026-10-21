import AppKit
import Combine
import Sparkle

/// Sparkle owns checking, verified downloads and installation. This object owns
/// only the app's reminder, leaving Sparkle's staged session free to resume.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var readyVersion: String?
    @Published private(set) var canCheck = false
    var willShowModalAlert: (() -> Void)?
    private var checkObservation: AnyCancellable?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true else { return }
        checkObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, state.stage == .downloaded || state.stage == .installing else { return }
        Task { @MainActor in self.readyVersion = update.displayVersionString }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in self.willShowModalAlert?() }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                            immediateInstallationBlock: @escaping () -> Void) -> Bool {
        Task { @MainActor in self.readyVersion = item.displayVersionString }
        // Returning true takes over (and stalls) the update session. Let
        // Sparkle continue, then checkForUpdates resumes its install UI.
        return false
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                            forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        let ready = choice == .dismiss && (state.stage == .downloaded || state.stage == .installing)
        Task { @MainActor in self.readyVersion = ready ? item.displayVersionString : nil }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearReminder()
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        clearReminder()
    }

    nonisolated func userDidCancelDownload(_ updater: SPUUpdater) { clearReminder() }

    private nonisolated func clearReminder() {
        Task { @MainActor in self.readyVersion = nil }
    }
}
