#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    private func makeFolder() throws -> String {
        var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
        let made = try #require(mkdtemp(&template).map { String(cString: $0) })
        return try #require(RealPath.resolve(made))
    }

    private func write(_ root: String, _ relative: String) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: path))
    }

    @Test func filesChangedDuringTheSessionAreFoundOthersAreNot() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Before the session: the owner's own build files.
        for file in ["Makefile", "package.json", ".vscode/launch.json", "src/main.c"] { try write(root, file) }
        usleep(20_000)
        let start = Date()
        usleep(20_000)
        // During it: an edit to one of them, new ones, and files nobody runs.
        try write(root, "Makefile")
        for file in [
            ".vscode/tasks.json", "App.xcodeproj/project.pbxproj", ".githooks/pre-commit", "src/other.c",
            "node_modules/x/package.json", ".git/hooks/post-checkout", ".git/config",
        ] {
            try write(root, file)
        }
        #expect(symlink("/tmp/elsewhere", root + "/.envrc") == 0)
        let scan = OwnerRunFileScan.scan(root: root, since: start, agentUID: nil)
        #expect(
            scan.files.map(\.path) == [
                ".envrc", ".git/hooks/post-checkout", ".githooks/pre-commit", ".vscode/tasks.json",
                "App.xcodeproj/project.pbxproj", "Makefile",
            ]
        )
        #expect(scan.files.allSatisfy { !$0.createdByAgent } && !scan.incomplete)
        // Files the agent owns count whenever they were written; here the test user stands in for the agent.
        let owned = OwnerRunFileScan.scan(root: root, since: Date(), agentUID: getuid())
        #expect(owned.files.map(\.path).contains("package.json") && owned.files.allSatisfy(\.createdByAgent))
    }

    @Test func theScanStopsAtItsLimitAndSaysSo() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<30 { try write(root, "d\(index)/Makefile") }
        let scan = OwnerRunFileScan.scan(root: root, since: .distantPast, agentUID: nil, limit: 10)
        #expect(scan.incomplete && scan.scanned == 11)
    }
#endif
