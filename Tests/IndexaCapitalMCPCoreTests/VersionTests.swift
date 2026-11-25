import Foundation
import Testing

@testable import IndexaCapitalMCPCore

/// The installer keys on the manifest version alone, so a build whose three version strings
/// disagree is a bug report that describes a build nobody has. Reads this repository's own
/// files, not the machine.
@Suite("Release metadata")
struct VersionTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifestVersion = try #require(try manifest()["version"] as? String)
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(manifestVersion == IndexaCapitalMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == IndexaCapitalMCPServer.version)
    }

    @Test("The manifest name and the plist identifier match the server")
    func namesAgree() throws {
        #expect(try manifest()["name"] as? String == IndexaCapitalMCPServer.name)
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleName"] as? String == IndexaCapitalMCPServer.name)
        #expect(plist["CFBundleIdentifier"] as? String == "codes.eneko.\(IndexaCapitalMCPServer.name)")
    }

    @Test("The manifest asks for no user configuration, because the server reads none")
    func noUserConfig() throws {
        let manifest = try manifest()
        #expect(manifest["user_config"] == nil)
        let server = try #require(manifest["server"] as? [String: Any])
        let config = try #require(server["mcp_config"] as? [String: Any])
        #expect((config["args"] as? [Any])?.isEmpty == true)
    }

    @Test("The Info.plist declares no usage description, because nothing here is TCC-gated")
    func plistHasNoUsageDescriptions() throws {
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(!plist.keys.contains { $0.hasSuffix("UsageDescription") })
    }

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
