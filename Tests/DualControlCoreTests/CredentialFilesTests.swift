import Foundation
import Testing

@testable import DualControlCore

/// A PEM header like a private key's, built here so no key-shaped literal sits in the repository for secret scanners.
private func header(_ label: String) -> String {
    "-----" + "BEGIN " + label + "KEY-----"
}

private func kinds(_ name: String, _ content: String = "") -> [String] {
    CredentialFiles.kinds(path: name, head: Array(content.utf8))
}

// MARK: - What looks like a credential

@Test(arguments: [
    ("id_rsa", "private key file"), ("id_ed25519", "private key file"), (".ssh/id_ecdsa", "private key file"),
    ("server.pem", "key or certificate file"), ("tls.key", "key or certificate file"),
    ("cert.p12", "key or certificate file"), (".aws/credentials", "AWS credentials file"),
    (".netrc", "login file (.netrc)"), ("client_secret_123.apps.json", "OAuth client secret file"),
    (".git-credentials", "git credentials file"),
])
func credentialFileNamesAreRecognised(_ path: String, _ kind: String) {
    #expect(kinds(path).contains(kind), "\(path)")
}

@Test(arguments: ["id_rsa.pub", "README.md", "main.c", "keys.swift", "package.json"])
func ordinaryNamesAreNot(_ path: String) {
    #expect(kinds(path, "nothing secret here").isEmpty, "\(path)")
}

@Test func secretsInsideFilesAreRecognised() {
    let token = String(repeating: "A", count: 36)
    #expect(kinds("notes.txt", header("OPENSSH PRIVATE ") + "\nabc") == ["private key"])
    #expect(kinds("a", header("RSA PRIVATE ")) == ["private key"])
    #expect(kinds("a", header("PRIVATE ")) == ["private key"])
    #expect(kinds("a", header("ENCRYPTED PRIVATE ")) == ["private key"])
    #expect(kinds(".env", "KEY=sk-ant-api03-" + String(repeating: "x", count: 40)) == ["Anthropic API key"])
    #expect(kinds("a", "token ghp_\(token)") == ["GitHub token"])
    #expect(kinds("a", "gho_\(token)") == ["GitHub token"])
    #expect(kinds("a", "github_pat_11ABCDEFG0" + String(repeating: "b", count: 40)) == ["GitHub token"])
    #expect(kinds("a", "AKIAIOSFODNN7EXAMPLE") == ["AWS access key"])
    #expect(kinds("a", "aws_secret_access_key = abc") == ["AWS secret key"])
    #expect(kinds("token.json", #"{"access_token": "x", "refresh_token": "y"}"#) == ["OAuth tokens"])
    #expect(kinds("creds.json", #"{"installed": {"client_secret": "x"}}"#) == ["OAuth tokens"])
}

@Test func lookalikesAreNot() {
    // Too short, wrong case, or only mentioned in prose.
    #expect(kinds("a", "sk-ant-short").isEmpty)
    #expect(kinds("a", "ghp_tooShort").isEmpty)
    #expect(kinds("a", "akiaiosfodnn7example").isEmpty)
    #expect(kinds("a", "BEGIN PUBLIC KEY").isEmpty)
    #expect(kinds("a", "-----BEGIN CERTIFICATE-----").isEmpty)
    // OAuth words count only in JSON files.
    #expect(kinds("notes.md", "the refresh_token field").isEmpty)
}

@Test func severalKindsAreListedOnce() {
    let token = String(repeating: "A", count: 36)
    let found = kinds("id_rsa", header("RSA PRIVATE ") + " ghp_\(token) ghp_\(token)")
    #expect(found == ["private key file", "private key", "GitHub token"])
}

@Test func claudeCodesOwnLoginFolderIsLeftOut() {
    #expect(CredentialFiles.isExcluded(".claude/.credentials.json", inAgentHome: true))
    #expect(CredentialFiles.isExcluded(".claude/settings.json", inAgentHome: true))
    #expect(CredentialFiles.isExcluded(".CLAUDE/x", inAgentHome: true))
    #expect(!CredentialFiles.isExcluded(".claude/.credentials.json", inAgentHome: false))
    #expect(!CredentialFiles.isExcluded(".ssh/id_rsa", inAgentHome: true))
}

// MARK: - The report

@Test func theReportWarnsLoudlyWithPathsAndKindsButNeverTheSecret() {
    var report = SessionReport.make(lines: [])
    let secret = "sk-ant-api03-" + String(repeating: "z", count: 40)
    _ = secret
    report.credentialFiles = CredentialScan(
        files: [
            CredentialFile(place: .sessionFolder, path: "src/.env", kinds: ["Anthropic API key"]),
            CredentialFile(place: .agentHome, path: ".ssh/id_ed25519", kinds: ["private key file"]),
        ],
        unreadable: [CredentialFile(place: .agentHome, path: ".aws", kinds: [])],
        scanned: 12,
        incomplete: false
    )
    let markdown = report.markdown
    #expect(markdown.contains("## Credentials ⚠️"))
    #expect(markdown.contains("**2 changed file(s) look like credentials.**"))
    #expect(markdown.contains("| session folder | src/.env | Anthropic API key |"))
    #expect(markdown.contains(#"| agent home | .ssh/id\_ed25519 | private key file |"#))
    #expect(markdown.contains("could not read") && markdown.contains(".aws"))
    #expect(markdown.contains("Claude Code's login folder"))
    #expect(!markdown.contains("zzzz"))
}

@Test func aCleanScanSaysSo() {
    var report = SessionReport.make(lines: [])
    report.credentialFiles = CredentialScan(files: [], unreadable: [], scanned: 40, incomplete: false)
    #expect(report.markdown.contains("## Credentials\n"))
    #expect(report.markdown.contains("No file changed this session looks like a credential (40 entries checked"))
}

@Test func agentWrittenPathsCannotAddMarkdown() {
    var report = SessionReport.make(lines: [])
    report.credentialFiles = CredentialScan(
        files: [CredentialFile(place: .sessionFolder, path: "a|b](http://x)", kinds: ["private key"])],
        unreadable: [],
        scanned: 1,
        incomplete: false
    )
    #expect(!report.markdown.contains("](http://x)"))
}
