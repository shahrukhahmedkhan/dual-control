import Testing

@testable import DualControlCore

private let scope = try? SessionScope(ceiling: "/work", root: "/work/p")
private let install = "/work/.dual-control/toolchains/esp-idf-v5.4"

@Test func theToolchainFolderIsInTheWorkAreaButNotTheAgentsHome() throws {
    let scope = try #require(scope)
    #expect(scope.toolchains == "/work/.dual-control/toolchains")
    #expect(scope.toolchainStaging == "/work/.dual-control/toolchain-staging")
    #expect(!SessionScope.isStrictlyInside(scope.toolchains, scope.agentHome))
    #expect(!SessionScope.isStrictlyInside(scope.toolchainStaging, scope.agentHome))
}

@Test func anInstallIsANamedReleaseFolderInTheToolchainFolder() throws {
    let scope = try #require(scope)
    #expect(OwnerToolchain.install(of: install + "/idf/tools/idf.py", scope: scope) == install)
    #expect(OwnerToolchain.install(of: install + "/x", scope: scope) == install)
    for path in [
        install, "/work/.dual-control/toolchains/other/x", "/work/.dual-control/toolchains/esp-idf-master/x",
        "/work/.dual-control/toolchains/esp-idf-v5.4.sha256", "/work/.dual-control/agent-home/esp/esp-idf/x",
        "/work/.dual-control/toolchains/../agent-home/x", "/work/.dual-control/toolchain-staging/idf/x",
    ] {
        #expect(OwnerToolchain.install(of: path, scope: scope) == nil, "\(path)")
    }
    #expect(OwnerToolchain.installName(version: "v5.4") == "esp-idf-v5.4")
    #expect(OwnerToolchain.hashFile(of: install) == install + ".sha256")
}

@Test func linksMayLeadOnlyIntoTheInstallOrSystemFolders() {
    for real in [install + "/tools/x", install, "/opt/homebrew/Cellar/python@3.12/bin/python3.12", "/usr/bin/python3"] {
        #expect(OwnerToolchain.mayLink(to: real, install: install), "\(real)")
    }
    for real in [
        "/work/.dual-control/agent-home/x", "/work/p/x", "/usr/local/bin/python3", "/private/tmp/x", "/Users/Shared/x",
        "/work/.dual-control/toolchains/esp-idf-v5.3/x", install + "/../esp-idf-v5.3", "/opt/homebrewx",
    ] {
        #expect(!OwnerToolchain.mayLink(to: real, install: install), "\(real)")
    }
}

@Test func textNamingTheStagingFolderIsRelocatedAndBinariesAreLeftAlone() {
    let staging = "/work/.dual-control/toolchain-staging"
    let text = Array("#!\(staging)/tools/env/bin/python\nVIRTUAL_ENV=\(staging)/tools/env \(staging)/x\n".utf8)
    let moved = OwnerToolchain.relocated(text, from: staging, to: install)
    #expect(
        moved.map { String(decoding: $0, as: UTF8.self) }
            == "#!\(install)/tools/env/bin/python\nVIRTUAL_ENV=\(install)/tools/env \(install)/x\n"
    )
    #expect(OwnerToolchain.relocated(Array("nothing here".utf8), from: staging, to: install) == nil)
    #expect(OwnerToolchain.relocated([0] + Array("\(staging)/x".utf8), from: staging, to: install) == nil)
    #expect(OwnerToolchain.relocatedLink(staging + "/tools/x", from: staging, to: install) == install + "/tools/x")
    #expect(OwnerToolchain.relocatedLink(staging + "-other/x", from: staging, to: install) == nil)
    #expect(OwnerToolchain.relocatedLink("python3", from: staging, to: install) == nil)
}

@Test func theInstallingProfileWritesOnlyTheStagingFolder() throws {
    let scope = try #require(scope)
    let profile = try SandboxProfile.installing(scope: scope, proxyPort: 4321)
    #expect(profile.contains(#"(allow file-write* (subpath "/work/.dual-control/toolchain-staging"))"#))
    #expect(profile.contains(#"(allow file-read* (subpath "/work/.dual-control/toolchain-staging"))"#))
    #expect(!profile.contains("agent-home") && !profile.contains(#"(subpath "/work/p")"#))
    #expect(profile.contains(#"(allow network-outbound (remote tcp4 "localhost:4321"))"#))
    #expect(profile.hasSuffix("(deny file-read* file-write* (subpath \"/work/dual-control\"))\n"))
    // Neither CHANGING nor any other profile writes the staging or toolchain folder.
    let changing = try SandboxProfile.changing(scope: scope)
    #expect(!changing.contains("toolchain"))
    #expect(throws: SandboxProfile.Error.self) {
        try SandboxProfile.toolchainCopy(scope: scope, install: "/work/.dual-control/agent-home/esp")
    }
    let copy = try SandboxProfile.toolchainCopy(scope: scope, install: install)
    #expect(copy.contains("(allow file-write* (subpath \"\(install)\"))"))
}

/// Gap 10 for C1's profiles: outside the owner's home, the install and the owner's copy read only what CHANGING reads.
@Test func theInstallAndTheCopyReadOnlyChangingsAllowlistOutsideTheHome() throws {
    let scope = try SessionScope(ceiling: "/Users/o/Developer", root: "/Users/o/Developer/p")
    let install = scope.toolchains + "/esp-idf-v5.4"
    let xcode = "/Applications/Xcode.app/Contents/Developer"
    let darwin = "/private/var/folders/ab/cd/T"
    func outsideHome(_ profile: String) -> [String] {
        let all = profile.split(separator: "\n").map(String.init)
        guard let start = all.firstIndex(of: "(deny file-read*)") else { return [] }
        return Array(all[start..<min(start + 3, all.count)])
    }
    let changing = try SandboxProfile.changing(scope: scope, systemFolders: [darwin], toolchains: [xcode])
    let installing = try SandboxProfile.installing(scope: scope, systemFolders: [darwin], toolchains: [xcode])
    #expect(outsideHome(changing).count == 3)
    #expect(outsideHome(installing) == outsideHome(changing))
    #expect(installing.contains(#"(subpath "/Applications/Xcode.app")"#))
    #expect(throws: SandboxProfile.Error.self) { try SandboxProfile.installing(scope: scope, toolchains: ["/"]) }
    // The owner's copy gets the same system folders, without the agent's Darwin folders or an Xcode.
    let copy = outsideHome(try SandboxProfile.toolchainCopy(scope: scope, install: install))
    #expect(copy == outsideHome(try SandboxProfile.changing(scope: scope)))
    #expect(copy.count == 3 && !copy.joined().contains(darwin))
    // The deny comes before the home's own rules, so nothing outside the home is readable by default.
    for profile in [installing, try SandboxProfile.toolchainCopy(scope: scope, install: install)] {
        let all = profile.split(separator: "\n").map(String.init)
        let deny = try #require(all.firstIndex(of: "(deny file-read*)"))
        let home = try #require(all.firstIndex { $0 == #"(deny file-read* (subpath "/Users/o"))"# })
        #expect(deny < home)
    }
}
