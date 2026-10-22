import AppKit
import XCTest
import MSIScreenCore
@testable import MSIScreenMenu

@MainActor
final class DeviceTerminationTests: XCTestCase {
    func testActualDelegateDefersNativeAndUpdaterTerminationUntilRuntimeReadCleanup() async throws {
        let selected = try DeviceSupportStoreTests.selection()
        var release: CheckedContinuation<DeviceObservation, Error>?
        let control = DeviceControlStore(services: DeviceSupportStoreTests.services { _ in
            try await withCheckedThrowingContinuation { release = $0 }
        })
        // No application launch, native device clients, updater or RPC server.
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u5-termination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let machines = directory.appendingPathComponent("machines.json")
        try JSONEncoder().encode(MachineRegistry(machines: [])).write(to: machines)
        let preferences = MonitorPreferences(defaults: UserDefaults(suiteName: "msi-u5-test-" + UUID().uuidString)!, registryStore: MachineRegistryStore(url: machines))
        let delegate = StatusItemController(deviceControl: control, preferences: preferences)
        control.recheckMetadata = {}
        control.select(selected); control.read()
        for _ in 0..<1000 { if release != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(delegate.hasActiveOperation)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        // A selection change cancels the read but must not signal idle prematurely.
        control.select(nil)
        XCTAssertTrue(delegate.hasActiveOperation)
        release?.resume(throwing: CancellationError())
        for _ in 0..<1000 { if !control.busy { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(delegate.hasActiveOperation)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
    func testInitializationRequiresMatchingExternalSamplesAndSafeSettledState() {
        let before = StatusItemController.FixtureFrontmost(pid: 62017, bundleID: "com.openai.codex")
        let own = StatusItemController.FixtureFrontmost(pid: 71641, bundleID: "fixture")
        func verdict(_ after: StatusItemController.FixtureFrontmost?, safe: Bool = true, complete: Bool = true) -> String {
            StatusItemController.fixtureForegroundPreservation(before: before, after: after, fixturePID: own.pid,
                fixtureBundleID: own.bundleID, initializationComplete: complete, initializationBackgroundSafe: safe)
        }
        XCTAssertEqual(verdict(before), "OBSERVED_UNCHANGED")
        XCTAssertEqual(verdict(nil), "INCONCLUSIVE")
        XCTAssertEqual(verdict(.init(pid: 50503, bundleID: "com.apple.UserNotificationCenter")), "INCONCLUSIVE")
        XCTAssertEqual(verdict(own), "INCONCLUSIVE")
        XCTAssertEqual(verdict(before, safe: false), "INCONCLUSIVE") // active/key/sticky at settling cannot certify initialization.
        XCTAssertEqual(verdict(before, complete: false), "INCONCLUSIVE")
        XCTAssertEqual(StatusItemController.fixtureForegroundPreservation(before: own, after: own, fixturePID: own.pid,
            fixtureBundleID: own.bundleID, initializationComplete: true, initializationBackgroundSafe: true), "INCONCLUSIVE")
    }

    func testNaturalLaterForegroundSwitchDoesNotEraseInitializationOrBypassCurrentSafety() {
        let initial = StatusItemController.FixtureFrontmost(pid: 62017, bundleID: "com.openai.codex")
        let later = StatusItemController.FixtureFrontmost(pid: 50001, bundleID: "com.clickontyler.Tern")
        let own = StatusItemController.FixtureFrontmost(pid: 71641, bundleID: "fixture")
        let initialization = StatusItemController.fixtureForegroundPreservation(before: initial, after: initial,
            fixturePID: own.pid, fixtureBundleID: own.bundleID, initializationComplete: true, initializationBackgroundSafe: true)
        func safety(_ current: StatusItemController.FixtureFrontmost?, active: Bool = false, key: Bool = false, violation: Bool = false) -> String {
            StatusItemController.fixtureBackgroundSafety(current: current, fixturePID: own.pid, fixtureBundleID: own.bundleID,
                appIsActive: active, panelIsKey: key, violation: violation)
        }
        XCTAssertEqual(initialization, "OBSERVED_UNCHANGED")
        XCTAssertEqual(safety(initial), "PASS")
        XCTAssertEqual(safety(later), "PASS") // Parent's QA3: other applications naturally changed foreground.
        XCTAssertEqual(safety(nil), "INCONCLUSIVE")
        XCTAssertEqual(safety(own), "INCONCLUSIVE") // Contradictory inactive flag cannot override actual own foreground.
        XCTAssertEqual(safety(later, active: true), "INCONCLUSIVE")
        XCTAssertEqual(safety(later, key: true), "INCONCLUSIVE")
        XCTAssertEqual(safety(later, violation: true), "INCONCLUSIVE") // Later resignation never clears prior acquisition.
    }

    func testActualVerifierSeparatesVisibilityReadinessFromInitializationAndCurrentSafety() async throws {
        let verifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/verify.py")
        // Extract only the pure health predicate. Importing the verifier would
        // parse CLI arguments/start workflows; this test must never launch an app.
        let script = #"""
import ast, pathlib, sys
source = ast.parse(pathlib.Path(sys.argv[1]).read_text())
function = next(node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == 'support_fixture_health_status')
namespace = {}
exec(compile(ast.Module(body=[function], type_ignores=[]), '<fixture-health-predicate>', 'exec'), namespace)
check = namespace['support_fixture_health_status']
initial = {'pid': 62017, 'bundleID': 'com.openai.codex'}
later = {'pid': 50001, 'bundleID': 'com.clickontyler.Tern'}
value = {'pid': 71641, 'bundleID': 'fixture', 'checkedAtMilliseconds': 1000, 'initializationComplete': True,
    'initializationBackgroundSafe': True, 'appFinishedLaunching': True, 'foregroundPreservation': 'OBSERVED_UNCHANGED',
    'frontmostBefore': initial, 'frontmostAfter': initial, 'frontmostCurrent': later, 'currentBackgroundSafety': 'PASS',
    'appIsActive': False, 'panelIsKeyWindow': False, 'backgroundViolationObserved': False,
    'panelIsVisible': True, 'appIsHidden': False, 'panelIsMiniaturized': False, 'panelOcclusionVisible': False}
def status(**changes):
    return check({**value, **changes}, True, 1000)
assert status()['ready'] # Natural later foreground switch, even with occlusion, is not theft.
hidden = status(panelIsVisible=False)
assert hidden['backgroundInitialization'] == hidden['currentBackgroundSafety'] == 'PASS'
assert hidden['panelReadiness'] == 'INCONCLUSIVE' and not hidden['ready']
for changes in ({'appIsActive': True}, {'panelIsKeyWindow': True}, {'backgroundViolationObserved': True},
    {'frontmostCurrent': None}, {'frontmostCurrent': {'pid': 71641, 'bundleID': 'fixture'}},
    {'frontmostAfter': later}, {'frontmostBefore': None}, {'initializationBackgroundSafe': False},
    {'appIsHidden': True}, {'panelIsMiniaturized': True}, {'checkedAtMilliseconds': -3001}):
    assert not status(**changes)['ready'], changes
assert not check(None, True, 1000)['ready']
assert not check(value, False, 1000)['ready'] # Hidden exercise must not accidentally show a panel.
assert check({**value, 'panelIsVisible': False}, False, 1000)['ready']
print('fixture-health predicate: separate initialization/current safety/visibility regressions passed')
"""#
        let output = try await ProcessRunner.runStructured(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-B", "-c", script, verifier.path], timeout: 5))
        XCTAssertTrue(output.succeeded, String(decoding: output.stdout + output.stderr, as: UTF8.self))
    }

    func testGenericStatusItemKeepsSelectedObservationAndUpdateAccessibility() {
        let result = StatusItemController.statusItemDescription(title: "Selected endpoint", toolTip: "Local experimental\nLast explicit observation: not read", readyVersion: "0.3.1")
        XCTAssertTrue(result.label.contains("Selected endpoint")); XCTAssertTrue(result.label.contains("Update 0.3.1 ready"))
        XCTAssertTrue(result.toolTip.contains("Last explicit observation: not read")); XCTAssertTrue(result.toolTip.contains("Update 0.3.1 ready to install."))
        let plain = StatusItemController.statusItemDescription(title: "Selected endpoint", toolTip: "not read", readyVersion: nil)
        XCTAssertFalse(plain.label.contains("Update")); XCTAssertEqual(plain.toolTip, "not read")
    }

    func testSelectedOwnerControlsWhetherLegacyFailureAppearsInFooter() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u5-footer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let machines = directory.appendingPathComponent("machines.json")
        try JSONEncoder().encode(MachineRegistry(machines: [])).write(to: machines)
        let prefs = MonitorPreferences(defaults: UserDefaults(suiteName: "msi-u5-footer-" + UUID().uuidString)!, registryStore: MachineRegistryStore(url: machines))
        let inventory = DeviceInventoryStore(), control = DeviceControlStore(), store = MonitorStore()
        store.externalMutationActive = { true }; store.apply(machines: [], followUSB: false)
        XCTAssertNotNil(store.error)
        let view = MonitorView(store: store, prefs: prefs, computers: ComputersStore(preferences: prefs), updater: AppUpdater(),
            appSettings: AppSettings(), inventory: inventory, deviceControl: control, closeControls: {})
        XCTAssertEqual(view.selectedFooterError, store.error)
        inventory.select(nil)
        XCTAssertNil(view.selectedFooterError)
        inventory.selectBuiltInMonitor()
        XCTAssertEqual(view.selectedFooterError, store.error)
    }

    func testRuntimeReadIsRejectedWhileCompiledOwnerIsBusyBelowButton() async throws {
        let selected = try DeviceSupportStoreTests.selection()
        var reads = 0
        let control = DeviceControlStore(services: DeviceSupportStoreTests.services { _ in reads += 1; return try DeviceSupportStoreTests.observation(selected) })
        control.select(selected); control.externalMutationActive = { true }; control.read()
        XCTAssertFalse(control.busy); XCTAssertEqual(reads, 0)
    }
}
