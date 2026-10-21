import Sparkle
import XCTest
@testable import MSIScreenMenu

@MainActor
final class AppUpdaterTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(nanoseconds: 20_000_000) }

    func testStagedUpdateKeepsSparkleInControlAndCancelledDownloadClearsBadge() async throws {
        let subject = AppUpdater()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        var installed = false
        XCTAssertFalse(subject.updater(controller.updater, willInstallUpdateOnQuit: .empty(),
                                       immediateInstallationBlock: { installed = true }))
        try await settle()
        XCTAssertNotNil(subject.readyVersion)
        XCTAssertFalse(installed, "A background download must not install immediately")
        subject.userDidCancelDownload(controller.updater)
        try await settle()
        XCTAssertNil(subject.readyVersion)
    }

    func testDismissalKeepsOnlyDownloadedReminderAndAbortClearsIt() async throws {
        let subject = AppUpdater()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        for stage in [SPUUserUpdateStage.downloaded, .installing, .notDownloaded] {
            let encoder = NSKeyedArchiver(requiringSecureCoding: true)
            encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
            encoder.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
            encoder.finishEncoding()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
            decoder.requiresSecureCoding = true
            let state = try XCTUnwrap(SPUUserUpdateState(coder: decoder))
            decoder.finishDecoding()
            subject.updater(controller.updater, userDidMake: .dismiss, forUpdate: .empty(), state: state)
            try await settle()
            XCTAssertEqual(subject.readyVersion != nil, stage != .notDownloaded)
        }
        _ = subject.updater(controller.updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: {})
        try await settle()
        subject.updater(controller.updater, didAbortWithError: NSError(domain: "UpdateTest", code: 1))
        try await settle()
        XCTAssertNil(subject.readyVersion)
    }
}
