#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// D12d on real files, as the test user (the owner, in the app).
    private final class Fixture {
        let base: String
        let scope: SessionScope

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p/src", "/home/Developer/p/.git", "/home/Developer/.dual-control/agent-home/.ssh",
                "/home/Developer/.dual-control/agent-home/.claude", "/home/Developer/.dual-control/tmp", "/outside",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
        }

        deinit {
            _ = chmod(scope.agentHome + "/private", 0o700)
            try? FileManager.default.removeItem(atPath: base)
        }

        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private let anthropic = "sk-ant-api03-" + String(repeating: "q", count: 40)
    /// A PEM header like a private key's, built here so no key-shaped literal sits in the repository.
    private func header(_ label: String) -> String { "-----" + "BEGIN " + label + "PRIVATE KEY-----" }

    @Test func changedFilesThatLookLikeCredentialsAreFoundInBothPlaces() throws {
        let f = try Fixture()
        let start = Date().addingTimeInterval(-5)
        try f.write(f.scope.root + "/src/.env", "ANTHROPIC_API_KEY=\(anthropic)\n")
        try f.write(f.scope.root + "/src/main.c", "int main(void) { return 0; }\n")
        try f.write(f.scope.root + "/.git/config", anthropic)
        try f.write(f.scope.agentHome + "/.ssh/id_ed25519", header("OPENSSH ") + "\n")
        // Claude Code's own login is meant to be there.
        try f.write(f.scope.agentHome + "/.claude/.credentials.json", #"{"refresh_token": "\#(anthropic)"}"#)
        // A link to a secret elsewhere is not followed; a FIFO is not opened.
        try f.write(f.base + "/outside/secret.pem", header("RSA "))
        try FileManager.default.createSymbolicLink(
            atPath: f.scope.root + "/linked",
            withDestinationPath: f.base + "/outside/secret.pem"
        )
        #expect(mkfifo(f.scope.root + "/pipe", 0o600) == 0)

        let scan = CredentialFileScan.scan(scope: f.scope, since: start)
        #expect(
            scan.files == [
                CredentialFile(place: .sessionFolder, path: "src/.env", kinds: ["Anthropic API key"]),
                CredentialFile(place: .agentHome, path: ".ssh/id_ed25519", kinds: ["private key file", "private key"]),
            ]
        )
        #expect(scan.unreadable.isEmpty && !scan.incomplete)
    }

    @Test func filesFromBeforeTheSessionAreNotListed() throws {
        let f = try Fixture()
        try f.write(f.scope.root + "/src/.env", "KEY=\(anthropic)\n")
        let scan = CredentialFileScan.scan(scope: f.scope, since: Date().addingTimeInterval(60))
        #expect(scan.files.isEmpty && scan.unreadable.isEmpty && scan.scanned > 0)
    }

    @Test func whatTheOwnerCannotReadIsListedAsSuch() throws {
        let f = try Fixture()
        let start = Date().addingTimeInterval(-5)
        try FileManager.default.createDirectory(
            atPath: f.scope.agentHome + "/private",
            withIntermediateDirectories: false
        )
        try f.write(f.scope.agentHome + "/private/x", anthropic)
        try f.write(f.scope.root + "/locked.txt", anthropic)
        chmod(f.scope.root + "/locked.txt", 0)
        try f.write(f.scope.root + "/id_rsa", "x")
        chmod(f.scope.root + "/id_rsa", 0)
        chmod(f.scope.agentHome + "/private", 0)
        let scan = CredentialFileScan.scan(scope: f.scope, since: start)
        // Its name alone still says what an unreadable key file is.
        #expect(scan.files == [CredentialFile(place: .sessionFolder, path: "id_rsa", kinds: ["private key file"])])
        #expect(
            scan.unreadable == [
                CredentialFile(place: .sessionFolder, path: "locked.txt", kinds: []),
                CredentialFile(place: .agentHome, path: "private", kinds: []),
            ]
        )
    }

    @Test func theScanStopsAtItsLimit() throws {
        let f = try Fixture()
        for index in 0..<5 { try f.write(f.scope.root + "/f\(index)", "x") }
        #expect(CredentialFileScan.scan(scope: f.scope, since: nil, limit: 3).incomplete)
    }
#endif
