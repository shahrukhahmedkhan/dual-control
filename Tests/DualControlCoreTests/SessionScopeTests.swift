import Testing

@testable import DualControlCore

private let ceiling = "/Users/o/Developer"

private func scope(_ root: String = "/Users/o/Developer/p") throws -> SessionScope {
    try SessionScope(ceiling: ceiling, root: root)
}

@Test(
    arguments: [
        ("/Users/o", "/Users/o/Developer"),
        ("/Users/o/", "/Users/o/Developer"),
        ("/var/root", "/var/root/Developer"),
    ]
)
func theCeilingIsDeveloperInTheOwnersHome(_ home: String, _ expected: String) {
    #expect(SessionScope.developerCeiling(ownerHome: home) == expected)
}

@Test(arguments: ["", "relative", "/", "/Users/o/../x", "/Users/./o", "/Users//o", "/Users/o\0"])
func noCeilingForAnOddHome(_ home: String) {
    #expect(SessionScope.developerCeiling(ownerHome: home) == nil)
}

@Test func theCeilingNameIsFixed() {
    #expect(SessionScope.ceilingFolderName == "Developer")
    #expect(SessionScope.workAreaFolderName == ".dual-control")
}

@Test func workAreaIsUnderTheCeiling() throws {
    let scope = try scope()
    #expect(scope.workArea == "/Users/o/Developer/.dual-control")
    #expect(scope.agentHome == "/Users/o/Developer/.dual-control/agent-home")
    #expect(scope.agentTmp == "/Users/o/Developer/.dual-control/tmp")
}

@Test(
    arguments: [
        "/Users/o/Developer/p",
        "/Users/o/Developer/p/sub",
        "/Users/o/Developer/a b/ü",
    ]
)
func scopesInsideTheCeiling(_ root: String) throws {
    #expect(try scope(root).root == root)
}

@Test(
    arguments: [
        // The ceiling itself, and anything outside it.
        "/Users/o/Developer",
        "/Users/o",
        "/Users/o/Documents",
        "/Users/o/DeveloperX/p",
        "/Users/o/Developer2",
        "/",
        "/tmp/p",
        "/private/tmp/p",
        // Not canonical: the caller must resolve with realpath first.
        "/Users/o/Developer/p/",
        "/Users/o/Developer/./p",
        "/Users/o/Developer/../Documents",
        "/Users/o/Developer/p/..",
        "/Users/o/Developer//p",
        "Users/o/Developer/p",
        "",
        // Case variants are other byte strings; realpath returns the on-disk case.
        "/Users/o/developer/p",
        "/users/o/Developer/p",
        "/USERS/O/DEVELOPER/P",
        // The agent's own work area is never a session.
        "/Users/o/Developer/.dual-control",
        "/Users/o/Developer/.dual-control/agent-home",
        "/Users/o/Developer/.dual-control/tmp/x",
        "/Users/o/Developer/p\0",
    ]
)
func scopesOutsideOrOdd(_ root: String) {
    #expect(throws: SessionScope.Error.self) { try scope(root) }
}

@Test(arguments: ["", "relative", "/Users/o/Developer/", "/Users/o/../o/Developer", "/"])
func oddCeilingsAreRefused(_ odd: String) {
    #expect(throws: SessionScope.Error.self) { try SessionScope(ceiling: odd, root: odd + "/p") }
}

@Test(
    arguments: [
        ("/Users/o/Developer/p", true),
        ("/Users/o/Developer/p/a/b", true),
        ("/Users/o/Developer/p/..x", true),
        ("/Users/o/Developer/pq", false),
        ("/Users/o/Developer/q", false),
        ("/Users/o/Developer", false),
        ("/Users/o/Developer/.dual-control/tmp", false),
        ("/Users/o/Developer/p/../q", false),
        ("/Users/o/Developer/p/./a", false),
        ("/Users/o/Developer/p/", false),
        ("/Users/o/Developer/p//a", false),
        ("/Users/o/Developer/P", false),
        ("/Users/o/developer/p", false),
        ("/private/Users/o/Developer/p", false),
        ("Users/o/Developer/p", false),
        ("", false),
        ("/Users/o/Developer/p/\0", false),
    ]
)
func containment(_ path: String, _ inside: Bool) throws {
    #expect(try scope().contains(path) == inside)
}

/// Swift's `==` treats NFC and NFD as equal; the kernel compares bytes, so the scope does too.
@Test func containmentComparesBytes() throws {
    let nfc = try scope("/Users/o/Developer/caf\u{E9}")
    #expect(nfc.contains("/Users/o/Developer/caf\u{E9}/x"))
    #expect(!nfc.contains("/Users/o/Developer/cafe\u{301}/x"))
}

// MARK: - Self-protection

@Test(
    arguments: [
        "/Users/o/Developer/dual-control",
        "/Users/o/Developer/dual-control/dual-control",
        "/Users/o/Developer/dual-control/notes/x",
        // APFS is case-insensitive by default: these are the same folder.
        "/Users/o/Developer/Dual-Control",
        "/Users/o/Developer/DUAL-CONTROL/src",
        "/Users/o/Developer/.Dual-Control/tmp",
    ]
)
func theDualControlRepoAndWorkAreaAreNeverSessions(_ root: String) {
    #expect(throws: SessionScope.Error.self) { try scope(root) }
}

@Test func theProtectedRepoIsRefusedByName() {
    #expect(throws: SessionScope.Error.protected("/Users/o/Developer/dual-control/x")) {
        try scope("/Users/o/Developer/dual-control/x")
    }
}

@Test(arguments: ["/Users/o/Developer/dual-controlX", "/Users/o/Developer/dual", "/Users/o/Developer/p/dual-control"])
func similarNamesAreSessions(_ root: String) throws {
    #expect(try scope(root).root == root)
}

@Test func theProtectedListAlwaysHoldsTheRepo() throws {
    #expect(try scope().protectedPaths == ["/Users/o/Developer/dual-control"])
    let extra = try SessionScope(ceiling: ceiling, root: "/Users/o/Developer/p", protected: ["/Users/o/Developer/p/dc"])
    #expect(extra.protectedPaths == ["/Users/o/Developer/dual-control", "/Users/o/Developer/p/dc"])
}

@Test func detectedPackagesAreProtected() throws {
    let detected = ["/Users/o/Developer/team/clone"]
    for root in ["/Users/o/Developer/team/clone", "/Users/o/Developer/team/clone/Sources"] {
        #expect(throws: SessionScope.Error.protected(root)) {
            try SessionScope(ceiling: ceiling, root: root, protected: detected)
        }
    }
    // A folder that holds a clone may be a session; the sandbox denies the clone itself.
    let team = try SessionScope(ceiling: ceiling, root: "/Users/o/Developer/team", protected: detected)
    #expect(team.protectedPaths.contains("/Users/o/Developer/team/clone"))
}

@Test(arguments: ["relative", "/", "/Users/o/Developer/p/", "/Users/o/../x"])
func oddProtectedPathsAreRefused(_ odd: String) {
    #expect(throws: SessionScope.Error.self) {
        try SessionScope(ceiling: ceiling, root: "/Users/o/Developer/p", protected: [odd])
    }
}

@Test(
    arguments: [
        (
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"DualControl\",\n",
            true
        ),
        ("let package=Package(name:\"DualControl\")", true),
        ("let p = Package( name : \"DualControl\" , platforms: [])", true),
        ("let package = Package(name: \"DualControlKit\")", false),
        ("let package = Package(name: \"Other\")", false),
        ("// DualControl\nlet package = Package(name: \"Other\")", false),
        ("", false),
    ]
)
func dualControlManifests(_ manifest: String, _ declares: Bool) {
    #expect(SessionScope.declaresDualControlPackage(manifest) == declares)
}
