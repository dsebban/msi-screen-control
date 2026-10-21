import Foundation
import XCTest
@testable import MSIScreenMenu

final class AgentSkillInstallerTests: XCTestCase {
    func testCompleteInstallIsRepeatableAndPreservesUserEdits() throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let destination = fixture.appendingPathComponent("home/.agents/skills/msi-screen-control")
        try files.createDirectory(at: source.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("commands".utf8).write(to: source.appendingPathComponent("references/commands.md"))

        try AgentSkillInstaller.install(from: source, to: destination)
        XCTAssertTrue(files.contentsEqual(atPath: source.path, andPath: destination.path))
        try AgentSkillInstaller.install(from: source, to: destination)
        let edited = destination.appendingPathComponent("references/commands.md")
        try Data("user edit".utf8).write(to: edited)
        XCTAssertThrowsError(try AgentSkillInstaller.install(from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: edited), "user edit")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [AgentSkillInstaller.name])
    }

    func testMissingSourceAndDanglingDestinationDoNotOverwriteAnything() throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: fixture) }
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)
        let source = fixture.appendingPathComponent("source")
        let destination = fixture.appendingPathComponent("destination")
        XCTAssertThrowsError(try AgentSkillInstaller.install(from: source, to: destination))
        XCTAssertFalse(files.fileExists(atPath: destination.path))
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try files.createSymbolicLink(atPath: destination.path, withDestinationPath: "missing")
        XCTAssertThrowsError(try AgentSkillInstaller.install(from: source, to: destination))
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: destination.path), "missing")
    }
}
