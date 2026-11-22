#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    /// A fresh, resolved temporary folder (`/tmp` is a symlink to `/private/tmp`).
    private func temporaryFolder() throws -> String {
        var template = Array("/tmp/dc-ceiling-XXXXXX".utf8CString)
        let made = try #require(mkdtemp(&template).map { String(cString: $0) })
        return try #require(RealPath.resolve(made))
    }

    private func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @Test func realpathResolvesPrivateDotsSymlinksAndCase() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(base.hasPrefix("/private/tmp/dc-ceiling-"))
        try makeFolder(base + "/Developer/Proj/sub")
        try makeFolder(base + "/outside")
        #expect(symlink(base + "/outside", base + "/Developer/Proj/escape") == 0)

        let viaTmp = "/tmp/" + base.dropFirst("/private/tmp/".count)
        #expect(RealPath.resolve(viaTmp + "/Developer/Proj") == base + "/Developer/Proj")
        #expect(RealPath.resolve(base + "/Developer/Proj/sub/../../Proj/./sub/") == base + "/Developer/Proj/sub")
        #expect(RealPath.resolve(base + "/Developer/Proj/escape") == base + "/outside")
        #expect(RealPath.resolve(base + "/Developer/Proj/sub/../escape") == base + "/outside")
        #expect(RealPath.resolve(base + "/Developer/Proj/missing") == nil)
        #expect(RealPath.resolve(base + "/Developer/Proj\0/sub") == nil)
        #expect(RealPath.resolve("relative") == nil)
        #expect(RealPath.resolve("") == nil)
        // The default macOS volume ignores case; realpath answers with the case on disk.
        if let folded = RealPath.resolve(base + "/DEVELOPER/proj") {
            #expect(folded == base + "/Developer/Proj")
        }
    }

    @Test func scopesAreResolvedBeforeTheyAreChecked() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let ceiling = base + "/Developer"
        try makeFolder(ceiling + "/Proj")
        try makeFolder(ceiling + "/.dual-control/tmp")
        try makeFolder(base + "/outside")
        #expect(symlink(base + "/outside", ceiling + "/escape") == 0)
        #expect(symlink(ceiling + "/Proj", base + "/outside/back-in") == 0)
        let viaTmp = "/tmp/" + base.dropFirst("/private/tmp/".count) + "/Developer"

        let direct = try ResolvedScope.make(choosing: ceiling + "/Proj", ceiling: ceiling)
        #expect(direct.root == ceiling + "/Proj")
        #expect(direct.ceiling == ceiling)
        #expect(try ResolvedScope.make(choosing: viaTmp + "/Proj", ceiling: viaTmp).root == ceiling + "/Proj")
        #expect(try ResolvedScope.make(choosing: base + "/outside/back-in", ceiling: ceiling).root == ceiling + "/Proj")
        if (try? ResolvedScope.make(choosing: ceiling + "/proj", ceiling: ceiling)) != nil {
            #expect(try ResolvedScope.make(choosing: ceiling + "/proj", ceiling: ceiling).root == ceiling + "/Proj")
        }

        for refused in [
            ceiling, ceiling + "/escape", ceiling + "/Proj/../../outside", base + "/outside", ceiling + "/missing",
            ceiling + "/.dual-control", ceiling + "/.dual-control/tmp", "/private/tmp", "/",
        ] {
            #expect(throws: (any Error).self, "\(refused)") {
                try ResolvedScope.make(choosing: refused, ceiling: ceiling)
            }
        }
        #expect(throws: (any Error).self) {
            try ResolvedScope.make(choosing: ceiling + "/Proj", ceiling: base + "/nope")
        }
    }

    @Test func theResolverChecksAgainstTheResolvedScope() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let ceiling = base + "/Developer"
        try makeFolder(ceiling + "/Proj/sub")
        try makeFolder(ceiling + "/Other")
        #expect(symlink(ceiling + "/Other", ceiling + "/Proj/to-other") == 0)
        let scope = try ResolvedScope.make(choosing: ceiling + "/Proj", ceiling: ceiling)
        #expect(RealPath.resolve(ceiling + "/Proj/sub").map(scope.contains) == true)
        #expect(RealPath.resolve(ceiling + "/Proj/to-other").map(scope.contains) == false)
        #expect(RealPath.resolve(ceiling + "/Proj/sub/../../Other").map(scope.contains) == false)
    }

    private let manifest = "// swift-tools-version: 6.0\nlet package = Package(\n    name: \"DualControl\",\n)\n"

    private func writeManifest(_ folder: String, _ text: String = manifest) throws {
        try makeFolder(folder)
        try Data(text.utf8).write(to: URL(fileURLWithPath: folder + "/Package.swift"))
    }

    @Test func theDualControlRepoIsNeverASession() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let ceiling = base + "/Developer"
        try makeFolder(ceiling + "/dual-control/dual-control/Sources")
        try makeFolder(ceiling + "/dual-control/notes")
        for refused in [
            ceiling + "/dual-control", ceiling + "/dual-control/dual-control/Sources",
            ceiling + "/dual-control/notes",
            ceiling + "/DUAL-CONTROL/notes",
        ] {
            #expect(throws: (any Error).self, "\(refused)") {
                try ResolvedScope.make(choosing: refused, ceiling: ceiling)
            }
        }
    }

    @Test func foldersDeclaringTheDualControlPackageAreProtected() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let ceiling = base + "/Developer"
        try writeManifest(ceiling + "/team/clone")
        try makeFolder(ceiling + "/team/clone/Sources/Core")
        try writeManifest(ceiling + "/team/a/b/c/deep")
        try writeManifest(ceiling + "/team/other", "let package = Package(name: \"Other\")\n")
        try writeManifest(ceiling + "/team/node_modules/skipped")

        // The clone itself, or anything inside it, is refused.
        for refused in [ceiling + "/team/clone", ceiling + "/team/clone/Sources/Core"] {
            #expect(throws: ResolvedScope.Error.refused(.protected(refused))) {
                try ResolvedScope.make(choosing: refused, ceiling: ceiling)
            }
        }
        // A folder holding clones is a session; the clones go on the protected list for the sandbox.
        let team = try ResolvedScope.make(choosing: ceiling + "/team", ceiling: ceiling)
        #expect(
            team.protectedPaths == [
                ceiling + "/dual-control", ceiling + "/team/a/b/c/deep", ceiling + "/team/clone",
            ]
        )
    }

    /// The production ceiling is fixed: the owner's home from the password database (never `$HOME`) plus
    /// `Developer`, resolved. Nothing configures it.
    @Test func theProductionCeilingIsFixed() throws {
        let entry = try #require(getpwuid(getuid()))
        let home = String(cString: entry.pointee.pw_dir)
        #expect(DeveloperCeiling.ownerHome() == home)
        let expected = RealPath.resolve(home + "/Developer")
        #expect(DeveloperCeiling.resolve() == expected)
    }
#endif
