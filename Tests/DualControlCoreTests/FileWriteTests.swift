import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func call(_ tool: String, _ arguments: [String: JSONValue]) -> IPCRequest {
    IPCRequest(id: "1", tool: tool, arguments: arguments)
}

private func write(_ path: String = "/work/p/src/main.c", _ content: String = "int main(void) { return 0; }\n")
    -> IPCRequest
{
    call("write_file", ["path": .string(path), "content": .string(content)])
}

private func patch(_ path: String = "/work/p/src/main.c", _ text: String) -> IPCRequest {
    call("apply_patch", ["path": .string(path), "patch": .string(text)])
}

/// A session in /work/p where `links` maps paths to what they resolve to (symbolic links); every other path resolves
/// to itself, except `missing` ones.
private func supervisor(
    _ mode: ApprovalMode,
    links: [String: String] = [:],
    missing: Set<String> = [],
    protected: [String] = []
) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p", protected: protected),
        sandboxProblem: nil,
        resolvePath: { path in missing.contains(path) ? nil : links[path] ?? path }
    )
    supervisor.setMode(mode, now: start)
    return supervisor
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func applied(_ diff: String, to text: String) -> Result<String, UnifiedPatch.Problem> {
    switch UnifiedPatch.parse(diff) {
    case .failure(let problem): return .failure(problem)
    case .success(let patch): return patch.apply(to: bytes(text)).map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - Patches

@Test func aHunkReplacesTheLinesItNamesAndKeepsTheRest() {
    let diff = """
        --- a/main.c
        +++ b/main.c
        @@ -2,3 +2,3 @@
         two
        -three
        +THREE
         four

        """
    #expect(applied(diff, to: "one\ntwo\nthree\nfour\nfive\n") == .success("one\ntwo\nTHREE\nfour\nfive\n"))
}

@Test func hunksApplyInOrderAndMayAddOrRemoveLines() {
    let diff = """
        @@ -1,2 +1,3 @@
         a
        +a2
         b
        @@ -5,2 +6,1 @@
         e
        -f

        """
    #expect(applied(diff, to: "a\nb\nc\nd\ne\nf\n") == .success("a\na2\nb\nc\nd\ne\n"))
}

@Test func aHunkWhoseLineNumbersAreOffIsFoundWhereItsLinesMatchOnce() {
    // The header says line 1, the lines are at line 3: found, because they match in one place only.
    let diff = "@@ -1,2 +1,2 @@\n x\n-y\n+Y\n"
    #expect(applied(diff, to: "a\nb\nx\ny\n") == .success("a\nb\nx\nY\n"))
}

@Test func aHunkThatMatchesNowhereFailsAndNamesTheHunk() {
    let diff = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n@@ -9,1 +9,1 @@\n-nothing like this\n+x\n"
    guard case .failure(let problem) = applied(diff, to: "a\nb\nc\n") else {
        Issue.record("applied")
        return
    }
    #expect(problem.description.contains("hunk 2"))
}

@Test func aHunkThatMatchesInSeveralPlacesAwayFromItsLineFails() {
    let diff = "@@ -1,1 +1,1 @@\n-x\n+y\n"
    guard case .failure(let problem) = applied(diff, to: "a\nx\nb\nx\n") else {
        Issue.record("applied")
        return
    }
    #expect(problem.description.contains("2 places"))
}

@Test func matchingIsByteExactNotUnicodeEquivalent() {
    // "é" precomposed in the file, decomposed in the patch: Swift strings call them equal; the patch must not.
    let diff = "@@ -1,1 +1,1 @@\n-caf\u{65}\u{301}\n+cafe\n"
    guard case .failure = applied(diff, to: "caf\u{E9}\n") else {
        Issue.record("applied")
        return
    }
}

@Test func theMissingNewlineMarkerIsHonoured() {
    let addNewline = "@@ -1,1 +1,1 @@\n-last\n\\ No newline at end of file\n+last\n"
    #expect(applied(addNewline, to: "last") == .success("last\n"))
    let dropNewline = "@@ -1,1 +1,1 @@\n-last\n+last\n\\ No newline at end of file\n"
    #expect(applied(dropNewline, to: "last\n") == .success("last"))
    // Without a marker, the end of the file keeps what it had.
    #expect(applied("@@ -1,1 +1,1 @@\n-a\n+b\n", to: "a") == .success("b"))
}

@Test func anEmptyLineInAHunkIsAnEmptyContextLine() {
    // Editors often strip the space of an empty context line.
    let diff = "@@ -1,3 +1,3 @@\n a\n\n-c\n+C\n"
    #expect(applied(diff, to: "a\n\nc\n") == .success("a\n\nC\n"))
}

@Test(arguments: [
    "", "just text\n", "--- a\n+++ b\n", "@@ nonsense @@\n x\n",
    "@@ -1,1 +1,1 @@\n?weird\n",
    // Two files in one patch.
    "--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-a\n+b\n--- a/y\n+++ b/y\n@@ -1,1 +1,1 @@\n-a\n+b\n",
    "diff --git a/x b/x\n@@ -1,1 +1,1 @@\n-a\n+b\ndiff --git a/y b/y\n@@ -1,1 +1,1 @@\n-a\n+b\n",
])
func patchesThatAreNotOneFilesHunksAreRefused(_ text: String) {
    guard case .failure = UnifiedPatch.parse(text) else {
        Issue.record("parsed")
        return
    }
}

@Test func aPatchCountsItsHunksAndLines() throws {
    let parsed = try UnifiedPatch.parse("@@ -1,2 +1,3 @@\n a\n-b\n+B\n+C\n@@ -9 +10 @@\n-z\n").get()
    #expect(parsed.hunks.count == 2 && parsed.added == 2 && parsed.removed == 2)
    #expect(parsed.stats == "2 hunks, +2 -2")
}

@Test func onlyUTF8TextIsPatched() {
    let parsed = try? UnifiedPatch.parse("@@ -1 +1 @@\n-a\n+b\n").get()
    guard case .failure(let problem)? = parsed?.apply(to: [0x61, 0xFF, 0x0A]) else {
        Issue.record("patched binary")
        return
    }
    #expect(problem.description.contains("UTF-8"))
}

// MARK: - Paths

@Test(arguments: [
    "relative/x", "/work/p/../q/x", "/work/p/./x", "/work/p//x", "/work/p/x/", "/", "/work/p/a\u{0}b",
    "/work/p/.git/config", "/work/p/repo/.git/hooks/pre-commit", "/work/p/repo/.GIT/HEAD", "/work/p/repo/.git",
    "/work/p/" + String(repeating: "n", count: 256),
])
func badPathsAreRefused(_ path: String) {
    #expect(FileWrite.pathProblem(path) != nil, "\(path)")
}

@Test(arguments: ["/work/p/x", "/work/p/src/main.c", "/work/p/.gitignore", "/work/p/git/.github/ci.yml"])
func plainPathsAreAccepted(_ path: String) {
    #expect(FileWrite.pathProblem(path) == nil, "\(path)")
}

// MARK: - Routing

@Test func writeFileCarriesPathSizeAndHashButNotTheContentInItsArguments() throws {
    guard case .action("write_file", let request) = ToolRouter.route(write("/work/p/src/a.txt", "hello\n")) else {
        Issue.record("not routed")
        return
    }
    #expect(request.capability == .file)
    #expect(request.cwd == "/work/p/src")
    #expect(request.payload == bytes("hello\n"))
    let digest = FileWrite.sha256(bytes("hello\n"))
    #expect(request.argv == ["write", "/work/p/src/a.txt", "6", digest])
    #expect(!request.argv.contains("hello\n"))
}

@Test func base64ContentIsDecoded() {
    let route = ToolRouter.route(
        call("write_file", ["path": .string("/work/p/blob.bin"), "content_base64": .string("AP8K")])
    )
    guard case .action(_, let request) = route else {
        Issue.record("not routed")
        return
    }
    #expect(request.payload == [0x00, 0xFF, 0x0A])
}

@Test(arguments: [
    ["path": JSONValue.string("/work/p/x")],
    ["path": .string("/work/p/x"), "content": .string("a"), "content_base64": .string("YQ==")],
    ["path": .string("/work/p/x"), "content_base64": .string("not base64!")],
    ["path": .string("/work/p/x"), "content": .string(String(repeating: "x", count: FileWrite.maxBytes + 1))],
    ["path": .string("/work/p/x"), "content": .string("a"), "mode": .string("755")],
    ["path": .string("/work/p/.git/config"), "content": .string("a")],
    ["path": .int(1), "content": .string("a")],
])
func badWriteFileCallsAreRefused(_ arguments: [String: JSONValue]) {
    guard case .invalid = ToolRouter.route(call("write_file", arguments)) else {
        Issue.record("routed")
        return
    }
}

@Test func applyPatchCarriesItsStatsAndThePatchAsPayload() {
    let text = "@@ -1 +1 @@\n-a\n+b\n"
    guard case .action("apply_patch", let request) = ToolRouter.route(patch("/work/p/x.txt", text)) else {
        Issue.record("not routed")
        return
    }
    #expect(request.capability == .file && request.cwd == "/work/p")
    #expect(
        request.argv == [
            "patch", "/work/p/x.txt", "\(text.utf8.count)", FileWrite.sha256(bytes(text)), "1 hunk, +1 -1",
        ]
    )
    #expect(request.payload == bytes(text))
    #expect(FileRequest(argv: request.argv)?.operation == .patch)
}

@Test func anUnparsablePatchIsRefusedBeforeAnyoneIsAsked() {
    guard case .invalid(_, let message) = ToolRouter.route(patch("/work/p/x.txt", "not a diff")) else {
        Issue.record("routed")
        return
    }
    #expect(message.contains("unified diff"))
}

// MARK: - Supervision

@Test func aWriteFollowsTheApprovalModeAndCannotBeAlwaysAllowed() throws {
    var asking = try supervisor(.askEach)
    guard case .pending = asking.submit(write(), now: start) else {
        Issue.record("did not ask")
        return
    }
    #expect(asking.pending.first?.tier == .changing)
    #expect(asking.pending.first?.canAlwaysAllow == false)
    var allowing = try supervisor(.allowWhileOpen)
    guard case .execute(let execution) = allowing.submit(write(), now: start) else {
        Issue.record("did not run")
        return
    }
    guard
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("did not launch")
        return
    }
    #expect(!launch.readOnly && launch.request.capability == .file)
}

@Test func theAuditNeverHoldsTheContent() throws {
    var allowing = try supervisor(.allowWhileOpen)
    let secret = "sk-ant-not-a-real-key-but-private"
    guard case .execute(let execution) = allowing.submit(write("/work/p/notes.txt", secret), now: start),
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("did not launch")
        return
    }
    _ = allowing.finishFile(launch, .success(FileWritten(bytes: secret.utf8.count, sha256: "ab")), now: start)
    let lines = allowing.drainAuditLines()
    #expect(!lines.isEmpty)
    #expect(!lines.contains { $0.contains(secret) })
    #expect(lines.contains { $0.contains("wrote \(secret.utf8.count) bytes, sha256 ab") })
    // The request's own encoding leaves the payload out, wherever it is written.
    let encoded = String(decoding: try JSONEncoder().encode(execution.request), as: UTF8.self)
    #expect(!encoded.contains("payload") && !encoded.contains(secret))
}

@Test func aWriteOutsideTheSessionFolderIsRefused() throws {
    var allowing = try supervisor(.allowWhileOpen, links: ["/work/p/out": "/work/q"])
    for path in ["/work/q/x", "/work/p/out/x", "/etc/hosts"] {
        guard case .finished(let result) = allowing.submit(write(path), now: start) else {
            Issue.record("ran \(path)")
            continue
        }
        #expect(result.isError)
    }
}

@Test func aSymbolicLinkIsNeverWrittenThrough() throws {
    var allowing = try supervisor(.allowWhileOpen, links: ["/work/p/link.txt": "/work/p/real.txt"])
    guard case .finished(let result) = allowing.submit(write("/work/p/link.txt"), now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError && result.text.contains("symbolic link"))
}

@Test func aLinkIntoAGitFolderIsRefused() throws {
    var allowing = try supervisor(.allowWhileOpen, links: ["/work/p/hooks": "/work/p/repo/.git/hooks"])
    guard case .finished(let result) = allowing.submit(write("/work/p/hooks/pre-commit"), now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError && result.text.contains(".git"))
}

@Test func aProtectedPathIsRefused() throws {
    var allowing = try supervisor(.allowWhileOpen, links: ["/work/p/dc": "/work/dual-control"])
    guard case .finished(let result) = allowing.submit(write("/work/p/dc/Package.swift"), now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError)
}

@Test func aMissingFolderIsRefusedWithAHint() throws {
    var allowing = try supervisor(.allowWhileOpen, missing: ["/work/p/new"])
    guard case .finished(let result) = allowing.submit(write("/work/p/new/x.txt"), now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError)
}

@Test func aFailedWriteIsReportedAndAudited() throws {
    var allowing = try supervisor(.allowWhileOpen)
    guard case .execute(let execution) = allowing.submit(patch(text: "@@ -1 +1 @@\n-a\n+b\n"), now: start),
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("did not launch")
        return
    }
    let problem = FileWrite.Problem(description: "hunk 1 does not match the file")
    let result = allowing.finishFile(launch, .failure(problem), now: start)
    #expect(result.isError && result.text.contains("hunk 1 does not match"))
    #expect(allowing.drainAuditLines().contains { $0.contains("failed: hunk 1 does not match") })
}

@Test func fileWritesAreChangingAndShownAsWhatTheyDo() {
    let request = ActionRequest(
        capability: .file,
        argv: ["patch", "/work/p/x.txt", "20", "ab", "1 hunk, +1 -1"],
        cwd: "/work/p",
        projectID: "/work/p"
    )
    #expect(Classifier.classify(request).tier == .changing)
    #expect(FileRequest(argv: request.argv)?.summary == "patch /work/p/x.txt (1 hunk, +1 -1)")
    #expect(FileRequest(argv: ["write", "/work/p/x", "3", "ab"])?.summary == "write /work/p/x (3 bytes)")
    #expect(FileRequest(argv: ["delete", "/work/p/x"]) == nil)
}

// MARK: - Agent-side scripts

@Test func theAgentSideScriptsTakeEverythingAsArguments() {
    let write = FileWrite.writeArgv(path: "/work/p/x", expected: .absentOrAny, content: [0x61])
    #expect(write == ["/bin/sh", "-c", FileWrite.writeScript, "write_file", "/work/p/x", "any", "YQ=="])
    let read = FileWrite.readArgv(path: "/work/p/x")
    #expect(read == ["/bin/sh", "-c", FileWrite.readScript, "read_file", "/work/p/x", "\(FileWrite.maxBytes)"])
    #expect(FileWrite.writeArgv(path: "/p/x", expected: .sha256("ab"), content: [])[5] == "ab")
    // Never follows a link, writes a temporary file next to the target and renames it into place.
    for part in ["-L \"$target\"", "mktemp", "/bin/mv -f"] { #expect(FileWrite.writeScript.contains(part), "\(part)") }
    #expect(FileWrite.readScript.contains("-L \"$target\""))
}

private func patch(text: String) -> IPCRequest { patch("/work/p/x.txt", text) }

// MARK: - Steps

private func outcome(_ status: Int32, _ output: String, killed: Bool = false) -> CommandOutcome {
    CommandOutcome(
        status: status,
        timedOut: false,
        killed: killed,
        duration: 0.1,
        output: output,
        totalBytes: output.utf8.count,
        shownBytes: output.utf8.count
    )
}

@Test func aPatchIsWrittenOnlyOverTheBytesItWasAppliedTo() throws {
    let text = "@@ -1 +1 @@\n-a\n+b\n"
    let request = FileWrite.patchRequest(path: "/p/x", text: text, patch: try UnifiedPatch.parse(text).get())
    #expect(FileWrite.needsCurrent(request))
    let plan = try FileWrite.contentToWrite(request, current: bytes("a\n")).get()
    #expect(plan.content == bytes("b\n") && plan.expected == .sha256(FileWrite.sha256(bytes("a\n"))))
    #expect(FileWrite.contentToWrite(request, current: nil).isFailure)
    // A payload that is not what the operands describe is never written.
    var forged = FileWrite.writeRequest(path: "/p/x", content: bytes("approved"))
    forged.payload = bytes("something else")
    #expect(FileWrite.contentToWrite(forged, current: nil).isFailure)
}

@Test func theScriptsOutcomesAreReadStrictly() {
    #expect(FileWrite.readResult(outcome(0, "YQo=\n")) == .success(bytes("a\n")))
    #expect(FileWrite.readResult(outcome(3, "dual-control: it is a symbolic link")).isFailure)
    #expect(FileWrite.readResult(outcome(0, "not base64")).isFailure)
    #expect(FileWrite.readResult(outcome(0, "YQo=", killed: true)).isFailure)
    let digest = FileWrite.sha256(bytes("b"))
    #expect(
        FileWrite.writeResult(outcome(0, digest + "\n"), content: bytes("b"))
            == .success(FileWritten(bytes: 1, sha256: digest))
    )
    #expect(FileWrite.writeResult(outcome(0, "00\n"), content: bytes("b")).isFailure)
    guard case .failure(let problem) = FileWrite.writeResult(outcome(6, ""), content: bytes("b")) else {
        Issue.record("accepted")
        return
    }
    #expect(problem.description.contains("changed"))
}

extension Result {
    fileprivate var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
