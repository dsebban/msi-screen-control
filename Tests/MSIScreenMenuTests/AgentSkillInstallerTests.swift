import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore
@testable import MSIScreenMenu

final class AgentSkillInstallerTests: XCTestCase {
    func fixture() throws -> (URL, SupportRegistry) {
        let url = URL(fileURLWithPath: "/private/tmp/msi-u4-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, try SupportRegistry(home: url.appendingPathComponent("support")))
    }
    func source(_ root: URL, _ skill: AgentSkill, version: String = "first") throws -> URL {
        let url = root.appendingPathComponent("source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("references"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("---\nname: \(skill.rawValue)\ndescription: Fixture\nmetadata:\n  msi-screen-host-api: \"1\"\n---\n\(version)".utf8).write(to: url.appendingPathComponent("SKILL.md"))
        try Data(version.utf8).write(to: url.appendingPathComponent("references/contract-v1.md"))
        try Data("validation".utf8).write(to: url.appendingPathComponent("references/validation.md"))
        try FileManager.default.createDirectory(at: url.appendingPathComponent("agents"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("interface: {}".utf8).write(to: url.appendingPathComponent("agents/openai.yaml"))
        return url
    }
    func testProspectiveActionUsesManagedOwnershipWithoutPublishingOrCreatingMissingParents() throws {
        let (root, registry) = try fixture(), old = try source(root, .writeSupport), new = try source(root, .writeSupport, version: "new")
        let destination = root.appendingPathComponent("missing/skills/write-addhoc-support")
        var retirements = 0
        let installer = AgentSkillInstallation(registry: registry) { _ in retirements += 1 }
        XCTAssertEqual(try installer.prospectiveAction(skill: .writeSupport, source: old, destination: destination), .install)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.home.appendingPathComponent("skill-installs.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.home.appendingPathComponent("skill-installer.lock").path))
        _ = try installer.install(skill: .writeSupport, source: old, destination: destination)
        let receipt = try Data(contentsOf: registry.home.appendingPathComponent("skill-installs.json"))
        XCTAssertEqual(try installer.prospectiveAction(skill: .writeSupport, source: old, destination: destination), .unchanged)
        XCTAssertEqual(try installer.prospectiveAction(skill: .writeSupport, source: new, destination: destination), .upgrade)
        XCTAssertEqual(try Data(contentsOf: registry.home.appendingPathComponent("skill-installs.json")), receipt)
        XCTAssertEqual(try AgentSkillTree.read(destination, source: false), try AgentSkillTree.read(old, source: true))
        XCTAssertEqual(retirements, 0)
        try Data("user edit".utf8).write(to: destination.appendingPathComponent("references/contract-v1.md"))
        XCTAssertThrowsError(try installer.prospectiveAction(skill: .writeSupport, source: new, destination: destination))
        XCTAssertEqual(try Data(contentsOf: registry.home.appendingPathComponent("skill-installs.json")), receipt)
    }
    func testTwoSkillsIndependentInstallNoOpAndEditedConflictThroughFacade() throws {
        let (root, registry) = try fixture(), files = FileManager.default
        for skill in AgentSkill.allCases {
            let original = try source(root, skill), destination = root.appendingPathComponent("skills/" + skill.rawValue)
            try AgentSkillInstaller.install(skill: skill, from: original, to: destination, registry: registry)
            let receipt = try Data(contentsOf: registry.home.appendingPathComponent("skill-installs.json"))
            try AgentSkillInstaller.install(skill: skill, from: original, to: destination, registry: registry)
            XCTAssertEqual(try Data(contentsOf: registry.home.appendingPathComponent("skill-installs.json")), receipt)
            XCTAssertEqual(try AgentSkillTree.read(original, source: true), try AgentSkillTree.read(destination, source: false))
            try Data("user edit".utf8).write(to: destination.appendingPathComponent("references/contract-v1.md"))
            XCTAssertThrowsError(try AgentSkillInstaller.install(skill: skill, from: original, to: destination, registry: registry))
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("references/contract-v1.md")), "user edit")
            XCTAssertTrue(files.fileExists(atPath: original.path))
        }
    }
    func testManagedUpgradeExchangesOnlyUnchangedOwnedTreeAndTrashesOldVersion() throws {
        let (root, registry) = try fixture(), old = try source(root, .writeSupport), new = try source(root, .writeSupport, version: "second")
        let destination = root.appendingPathComponent("skills/write-addhoc-support"), trashed = root.appendingPathComponent("owned-trash")
        var trashCalls = 0
        let installer = AgentSkillInstallation(registry: registry) { url in
            trashCalls += 1
            XCTAssertEqual(try AgentSkillTree.read(url, source: false), try AgentSkillTree.read(old, source: true))
            try FileManager.default.moveItem(at: url, to: trashed)
        }
        XCTAssertEqual(try installer.install(skill: .writeSupport, source: old, destination: destination), .installed)
        XCTAssertEqual(try installer.install(skill: .writeSupport, source: new, destination: destination), .upgraded)
        XCTAssertEqual(trashCalls, 1)
        XCTAssertEqual(try AgentSkillTree.read(destination, source: false), try AgentSkillTree.read(new, source: true))
        XCTAssertEqual(try installer.install(skill: .writeSupport, source: new, destination: destination), .unchanged)
        try Data("extra".utf8).write(to: destination.appendingPathComponent("extra"))
        XCTAssertThrowsError(try installer.install(skill: .writeSupport, source: old, destination: destination))
        XCTAssertEqual(trashCalls, 1)
    }
    func testUnrecordedExactContentNeverConfersUpgradeOwnership() throws {
        let (root, registry) = try fixture(), old = try source(root, .screenControl), new = try source(root, .screenControl, version: "second")
        let destination = root.appendingPathComponent("skills/msi-screen-control")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: old, to: destination)
        let installer = AgentSkillInstallation(registry: registry)
        XCTAssertEqual(try installer.prospectiveAction(skill: .screenControl, source: old, destination: destination), .unchanged)
        XCTAssertThrowsError(try installer.prospectiveAction(skill: .screenControl, source: new, destination: destination))
        XCTAssertEqual(try installer.install(skill: .screenControl, source: old, destination: destination), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.home.appendingPathComponent("skill-installs.json").path))
        XCTAssertThrowsError(try installer.install(skill: .screenControl, source: new, destination: destination))
        XCTAssertEqual(try AgentSkillTree.read(destination, source: false), try AgentSkillTree.read(old, source: true))
    }
    func testSourceDestinationAndNestedLiveDanglingHardLinksAreNeverFollowed() throws {
        for attack in ["source", "destination", "dangling", "nested", "hardlink"] {
            let (root, registry) = try fixture(), original = try source(root, .screenControl)
            let destination = root.appendingPathComponent("skills/msi-screen-control")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var input = original
            switch attack {
            case "source": input = root.appendingPathComponent("source-link"); XCTAssertEqual(symlink(original.path, input.path), 0)
            case "destination": XCTAssertEqual(symlink(original.path, destination.path), 0)
            case "dangling": XCTAssertEqual(symlink("missing", destination.path), 0)
            case "nested": XCTAssertEqual(symlink("missing", original.appendingPathComponent("references/linked").path), 0)
            default: XCTAssertEqual(link(original.appendingPathComponent("SKILL.md").path, original.appendingPathComponent("hard").path), 0)
            }
            XCTAssertThrowsError(try AgentSkillInstallation(registry: registry).prospectiveAction(skill: .screenControl, source: input, destination: destination))
            XCTAssertThrowsError(try AgentSkillInstaller.install(skill: .screenControl, from: input, to: destination, registry: registry))
            XCTAssertFalse(FileManager.default.fileExists(atPath: registry.home.appendingPathComponent("skill-installs.json").path))
        }
    }
    func testUnsupportedHeaderContractCannotBeSmuggledThroughBodyText() throws {
        let (root, registry) = try fixture(), original = try source(root, .writeSupport)
        let file = original.appendingPathComponent("SKILL.md")
        let text = try String(contentsOf: file).replacingOccurrences(of: "msi-screen-host-api: \"1\"", with: "msi-screen-host-api: \"99\"")
            + "\n  msi-screen-host-api: \"1\"\n"
        try Data(text.utf8).write(to: file)
        let destination = root.appendingPathComponent("skills/write-addhoc-support")
        XCTAssertThrowsError(try AgentSkillInstallation(registry: registry).install(skill: .writeSupport, source: original, destination: destination)) {
            XCTAssertEqual($0 as? AgentSkillInstallError, .incompatibleContract)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.home.appendingPathComponent("skill-installs.json").path))
    }
    func testReceiptCorruptionBusyAndMissingResourcePreservePublication() throws {
        let (root, registry) = try fixture(), old = try source(root, .screenControl), new = try source(root, .screenControl, version: "second")
        let destination = root.appendingPathComponent("skills/msi-screen-control"), installer = AgentSkillInstallation(registry: registry)
        _ = try installer.install(skill: .screenControl, source: old, destination: destination)
        do {
            let lock = try registry.root.lock("skill-installer.lock"); defer { withExtendedLifetime(lock) {} }
            XCTAssertThrowsError(try installer.install(skill: .screenControl, source: new, destination: destination))
        }
        let receipt = registry.home.appendingPathComponent("skill-installs.json")
        try Data("{\"schema\":99,\"installs\":{}}".utf8).write(to: receipt)
        XCTAssertThrowsError(try installer.install(skill: .screenControl, source: new, destination: destination))
        XCTAssertEqual(try AgentSkillTree.read(destination, source: false), try AgentSkillTree.read(old, source: true))
        XCTAssertThrowsError(try AgentSkillInstallation.bundledSkill(.writeSupport, executable: root.appendingPathComponent("msi-screen")))
        XCTAssertThrowsError(try AgentSkillInstallation.skillsHome(environment: ["MSI_SCREEN_AGENT_SKILLS_HOME": "relative"]))
    }
}
