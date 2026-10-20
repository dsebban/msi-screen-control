import XCTest
@testable import MSIScreenMenu
@testable import MSIScreenCore

final class LayoutApplicationTests: XCTestCase {
    private let mac = MachineDefinition(id: "mac", name: "Mac", platform: .macos, input: .usbc, host: nil)
    private let linux = MachineDefinition(id: "linux", name: "Linux", platform: .linux, input: .dp, host: "linux")
    private let baseline = ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: .pbp,
                                      source1: .hdmi1, source2: .usbc, pipInput: .usbc,
                                      pipSize: 2, pipPosition: 3)

    private func usb(_ route: KVMRoute, _ host: KVMControlHost) -> KVMStatus {
        KVMStatus(KVMSnapshot(model: "MD342CQP", protocolVersion: "V20", route: route),
                  host: host, machineID: "linux")
    }

    func testFullscreenLinuxStillAppliesWhenOnlyUSBNeedsMoving() {
        let target = ScreenController.fullscreenTarget(from: baseline, input: .dp)
        let application = LayoutApplication(target: target, machines: [mac, linux], followUSB: true)
        XCTAssertEqual(application.focusMachine, linux)
        XCTAssertEqual(application.command, "msi-screen machine focus linux")
        XCTAssertTrue(application.canApply(from: target, kvm: usb(.usbc, .local), localReadBlocked: false))
        XCTAssertFalse(application.canApply(from: target, kvm: usb(.upstream, .upstream), localReadBlocked: true))
        XCTAssertFalse(application.canApply(from: baseline, kvm: nil, localReadBlocked: false))
    }

    func testFullscreenMacCanReturnUSBFromLinux() {
        let target = ScreenController.fullscreenTarget(from: baseline, input: .usbc)
        let application = LayoutApplication(target: target, machines: [mac, linux], followUSB: true)
        XCTAssertEqual(application.focusMachine, mac)
        XCTAssertTrue(application.canApply(from: baseline, kvm: usb(.upstream, .upstream), localReadBlocked: true))
    }

    func testPBPAndDisabledFollowKeepExplicitUSBSelection() throws {
        let split = try ScreenController.pbpTarget(from: baseline, enabled: true, left: .dp, right: .usbc)
        let application = LayoutApplication(target: split, machines: [mac, linux], followUSB: true)
        XCTAssertNil(application.focusMachine)
        XCTAssertEqual(application.command, "msi-screen pbp on --left dp --right usbc")
        XCTAssertTrue(application.canApply(from: baseline, kvm: nil, localReadBlocked: false))
        XCTAssertTrue(application.canApply(from: baseline, kvm: usb(.upstream, .upstream), localReadBlocked: true))
        XCTAssertFalse(application.canApply(from: baseline, kvm: nil, localReadBlocked: true))
        let full = ScreenController.fullscreenTarget(from: baseline, input: .dp)
        let videoOnly = LayoutApplication(target: full, machines: [mac, linux], followUSB: false)
        XCTAssertNil(videoOnly.focusMachine)
        XCTAssertEqual(videoOnly.command, "msi-screen fullscreen dp")
        XCTAssertFalse(videoOnly.canApply(from: full, kvm: usb(.usbc, .local), localReadBlocked: false))
    }
}
