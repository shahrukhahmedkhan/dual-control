import Crypto
import Foundation

/// D12a: `write_file` and `apply_patch` write one file in the session folder, as the agent, in CHANGING. The request
/// the policy engine decides and the audit records is the operation, the path, and the size and SHA-256 of the
/// content (or patch); the bytes travel beside it (`ActionRequest.payload`) and are never encoded. The app runs fixed
/// scripts as the agent: one reads the file (for a patch), one writes a temporary file next to the target and renames
/// it into place, so a reader never sees half a file and a failure leaves the old one. Neither follows a symbolic link
/// at the target. Paths with a `.git` component are refused, and the kernel profile is the floor under all of it.
public enum FileWrite {
    /// The largest file written or patched, in bytes. Content goes to the agent as base64 in an argument, well under
    /// ARG_MAX.
    public static let maxBytes = 256 << 10
    /// The longest path accepted, in bytes.
    public static let maxPathBytes = 1024
    /// Seconds each script may take.
    public static let timeoutSeconds = 30

    /// What the write script requires of the target before it replaces it.
    public enum Expected: Sendable, Equatable {
        /// Anything (or nothing) may be there: `write_file`.
        case absentOrAny
        /// A regular file with exactly this SHA-256: `apply_patch`, so nothing changed since it was read.
        case sha256(String)

        var argument: String {
            switch self {
            case .absentOrAny: return "any"
            case .sha256(let digest): return digest
            }
        }
    }

    /// Why a file could not be written, for the caller's result and the audit.
    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        /// Why, in a phrase.
        public let description: String

        /// Creates a problem.
        public init(description: String) {
            self.description = description
        }
    }

    /// Why `path` may not be written, or `nil`: absolute and canonical (no `.`, `..` or empty components, no trailing
    /// slash), no NUL, at most `maxPathBytes` with names of at most 255 bytes, and no `.git` component in any case.
    public static func pathProblem(_ path: String) -> String? {
        guard path != "/", SessionScope.isCanonical(path) else {
            return "`path` must be an absolute file path without `.`, `..` or empty parts"
        }
        let parts = path.split(separator: "/")
        guard path.utf8.count <= maxPathBytes, parts.allSatisfy({ $0.utf8.count <= 255 }) else {
            return "`path` is too long"
        }
        if parts.contains(where: { $0.lowercased() == ".git" }) { return gitRefusal }
        return nil
    }

    static let gitRefusal = "files inside .git are never written; commit with git_commit"

    /// Why the agent may not write `path` (checked by `pathProblem`) in `scope`, or `nil`. `resolvedFolder` is its
    /// folder, already resolved and inside the session folder. The target must not be a symbolic link or resolve
    /// elsewhere, and neither it nor its resolved folder may be inside `.git` or a protected path.
    static func scopeProblem(
        _ path: String,
        resolvedFolder: String,
        scope: SessionScope,
        resolvePath: (String) -> String?
    ) -> String? {
        let name = String(path[path.index(after: path.lastIndex(of: "/") ?? path.startIndex)...])
        let target = resolvedFolder + "/" + name
        if target.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) { return gitRefusal }
        if scope.protectedPaths.contains(where: { SessionScope.isSameOrInsideIgnoringCase(target, $0) }) {
            return "\(DisplayText.escaped(path)) is in a protected folder"
        }
        if let resolved = resolvePath(path), resolved.lowercased() != target.lowercased() {
            return "\(DisplayText.escaped(path)) is a symbolic link; write the file it points to by its own path"
        }
        return nil
    }

    /// SHA-256 of `bytes`, lowercase hex.
    public static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The request `write_file` asks the policy engine about.
    static func writeRequest(path: String, content: [UInt8]) -> ActionRequest {
        request(argv: ["write", path, "\(content.count)", sha256(content)], path: path, payload: content)
    }

    /// The request `apply_patch` asks the policy engine about.
    static func patchRequest(path: String, text: String, patch: UnifiedPatch) -> ActionRequest {
        let bytes = Array(text.utf8)
        return request(
            argv: ["patch", path, "\(bytes.count)", sha256(bytes), patch.stats],
            path: path,
            payload: bytes
        )
    }

    private static func request(argv: [String], path: String, payload: [UInt8]) -> ActionRequest {
        // The folder stands in for the project and is resolved like a command's working directory.
        let folder = SandboxProfile.parent(of: path)
        var request = ActionRequest(
            capability: .file,
            argv: argv,
            cwd: folder,
            projectID: folder,
            timeoutSeconds: timeoutSeconds
        )
        request.payload = payload
        return request
    }

    /// The read script. `$1` is the file, `$2` the largest size. Prints the file as base64, or fails with exit 3
    /// (a symbolic link), 4 (not a regular file) or 5 (too large).
    public static let readScript = """
        set -eu
        target="$1"
        if [ -L "$target" ]; then echo "dual-control: it is a symbolic link" >&2; exit 3; fi
        if [ ! -f "$target" ]; then echo "dual-control: no such file; create it with write_file" >&2; exit 4; fi
        size=$(/usr/bin/stat -f %z -- "$target")
        if [ "$size" -gt "$2" ]; then echo "dual-control: the file is larger than $2 bytes" >&2; exit 5; fi
        /usr/bin/base64 -i "$target"
        """

    /// The write script. `$1` is the file, `$2` `any` or the SHA-256 it must have now, `$3` the content as base64.
    /// Writes a temporary file in the same folder (mode kept from the old file, or 0666 less the umask), renames it
    /// over the target and prints the new SHA-256. Fails with exit 3 (a symbolic link), 4 (not a regular file) or 6
    /// (changed since it was read), leaving the target as it was.
    public static let writeScript = """
        set -eu
        target="$1"
        expected="$2"
        folder="${target%/*}"
        if [ -L "$target" ]; then echo "dual-control: it is a symbolic link" >&2; exit 3; fi
        if [ -e "$target" ] && [ ! -f "$target" ]; then echo "dual-control: it is not a regular file" >&2; exit 4; fi
        if [ "$expected" != any ]; then
          current=$(/usr/bin/shasum -a 256 < "$target")
          if [ "${current%% *}" != "$expected" ]; then
            echo "dual-control: the file changed since it was read" >&2; exit 6
          fi
        fi
        tmp=$(/usr/bin/mktemp "$folder/.dual-control-write.XXXXXX")
        trap '/bin/rm -f -- "$tmp"' EXIT
        printf '%s' "$3" | /usr/bin/base64 -D -o "$tmp"
        if [ -f "$target" ]; then
          /bin/chmod "$(/usr/bin/stat -f %Lp -- "$target")" "$tmp"
        else
          /bin/chmod "$(printf '%o' $(( 0666 & ~$(umask) )))" "$tmp"
        fi
        /bin/mv -f -- "$tmp" "$target"
        trap - EXIT
        current=$(/usr/bin/shasum -a 256 < "$target")
        echo "${current%% *}"
        """

    /// The command line that reads `path` as the agent.
    public static func readArgv(path: String) -> [String] {
        ["/bin/sh", "-c", readScript, "read_file", path, "\(maxBytes)"]
    }

    /// The command line that writes `content` to `path` as the agent.
    public static func writeArgv(path: String, expected: Expected, content: [UInt8]) -> [String] {
        ["/bin/sh", "-c", writeScript, "write_file", path, expected.argument, Data(content).base64EncodedString()]
    }

    /// True if `request` needs the file's current bytes first: a patch.
    public static func needsCurrent(_ request: ActionRequest) -> Bool {
        FileRequest(argv: request.argv)?.operation == .patch
    }

    /// What to write for `request` and what the target must be until then: a write's content over anything, or the
    /// patched `current` bytes over exactly those bytes.
    public static func contentToWrite(
        _ request: ActionRequest,
        current: [UInt8]?
    ) -> Result<(content: [UInt8], expected: Expected), Problem> {
        guard let file = FileRequest(argv: request.argv), file.describes(request.payload), let payload = request.payload
        else { return .failure(Problem(description: "the request does not match its content")) }
        switch file.operation {
        case .write:
            return .success((payload, .absentOrAny))
        case .patch:
            guard let current else { return .failure(Problem(description: "the file was not read")) }
            switch UnifiedPatch.parse(String(decoding: payload, as: UTF8.self)).flatMap({ $0.apply(to: current) }) {
            case .failure(let problem): return .failure(Problem(description: problem.description))
            case .success(let patched): return .success((patched, .sha256(sha256(current))))
            }
        }
    }

    /// The file's bytes from the read script's outcome, or why not.
    public static func readResult(_ outcome: CommandOutcome) -> Result<[UInt8], Problem> {
        if let problem = outcomeProblem(outcome) { return .failure(problem) }
        let text = outcome.output.filter { $0 != "\n" }
        guard outcome.totalBytes == outcome.shownBytes, let data = Data(base64Encoded: text), data.count <= maxBytes
        else { return .failure(Problem(description: "the file could not be read")) }
        return .success(Array(data))
    }

    /// What the write script wrote, or why not: it must print the SHA-256 of exactly `content`.
    public static func writeResult(_ outcome: CommandOutcome, content: [UInt8]) -> Result<FileWritten, Problem> {
        if let problem = outcomeProblem(outcome) { return .failure(problem) }
        let digest = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest == sha256(content) else {
            return .failure(Problem(description: "the file changed while it was written; check it and try again"))
        }
        return .success(FileWritten(bytes: content.count, sha256: digest))
    }

    private static func outcomeProblem(_ outcome: CommandOutcome) -> Problem? {
        if outcome.timedOut { return Problem(description: "it timed out") }
        if outcome.killed { return Problem(description: "it was stopped") }
        guard outcome.status != 0 else { return nil }
        if let known = scriptProblem(status: outcome.status) { return known }
        if outcome.output.contains("Operation not permitted") {
            return Problem(description: "the sandbox refused it (exit \(outcome.status))")
        }
        return Problem(description: "it failed with exit status \(outcome.status)")
    }

    /// Why a script failed, from its exit status; `nil` for a status the scripts do not use.
    public static func scriptProblem(status: Int32) -> Problem? {
        switch status {
        case 3: return Problem(description: "the file is a symbolic link")
        case 4: return Problem(description: "it is not a regular file (apply_patch needs an existing file)")
        case 5: return Problem(description: "the file is larger than \(maxBytes) bytes")
        case 6: return Problem(description: "the file changed while it was being patched; try again")
        default: return nil
        }
    }
}

/// The operands of a `.file` request: `[operation, path, bytes, sha256]`, and for a patch its stats.
public struct FileRequest: Sendable, Equatable {
    /// What is done to the file.
    public enum Operation: String, Sendable {
        /// `write_file`: replaced by the content.
        case write
        /// `apply_patch`: the patch applied to it.
        case patch
    }

    /// What is done to the file.
    public let operation: Operation
    /// The file, as the call named it.
    public let path: String
    /// Bytes of the content (write) or of the patch text (patch).
    public let bytes: Int
    /// SHA-256 of those bytes.
    public let sha256: String
    /// A patch's "N hunks, +a -b"; empty for a write.
    public let stats: String

    /// Parses the operands; `nil` if they are not a file request.
    public init?(argv: [String]) {
        guard let first = argv.first, let operation = Operation(rawValue: first),
            argv.count == (operation == .write ? 4 : 5), let bytes = Int(argv[2])
        else { return nil }
        self.operation = operation
        path = argv[1]
        self.bytes = bytes
        sha256 = argv[3]
        stats = operation == .patch ? argv[4] : ""
    }

    /// One line for the feed and the approval prompt.
    public var summary: String {
        let shown = DisplayText.escaped(path)
        switch operation {
        case .write: return "write \(shown) (\(bytes) bytes)"
        case .patch: return "patch \(shown) (\(DisplayText.escaped(stats)))"
        }
    }

    /// True if `payload` is what the operands describe.
    public func describes(_ payload: [UInt8]?) -> Bool {
        guard let payload else { return false }
        return payload.count == bytes && FileWrite.sha256(payload) == sha256
    }
}

/// The hunks of a unified diff for one file, applied byte-exactly. Each hunk's old lines (context and removed) must
/// appear in the file: at the line its header names, or else in exactly one place after the previous hunk. There is
/// no fuzz: a hunk that matches nowhere, or in several places, fails the whole patch and nothing is written. Header
/// counts are not trusted; a hunk is the lines up to the next `@@`.
public struct UnifiedPatch: Sendable, Equatable {
    /// One `@@` hunk.
    public struct Hunk: Sendable, Equatable {
        /// The header's old start line (1-based; 0 for an insertion at the top).
        public let oldStart: Int
        /// The header as written, for messages.
        public let header: String
        /// Context and removed lines.
        public let old: [[UInt8]]
        /// Context and added lines.
        public let new: [[UInt8]]
        /// The old side's last line has no newline (`\ No newline at end of file`).
        public let oldNoNewline: Bool
        /// The new side's last line has no newline.
        public let newNoNewline: Bool
    }

    /// Why a patch cannot be read or applied.
    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        /// Why, naming the hunk.
        public let description: String
    }

    /// The hunks, in order.
    public let hunks: [Hunk]
    /// Lines added.
    public let added: Int
    /// Lines removed.
    public let removed: Int

    /// "N hunks, +a -b".
    public var stats: String {
        "\(hunks.count) hunk\(hunks.count == 1 ? "" : "s"), +\(added) -\(removed)"
    }

    /// Reads the hunks of a unified diff for one file. Before the first hunk only `diff `, `index `, `--- ` and
    /// `+++ ` lines may appear, at most once each; a second file's header fails it.
    public static func parse(_ text: String) -> Result<UnifiedPatch, Problem> {
        let notDiff = Problem(description: "the patch is not a unified diff of one file (hunks starting with @@)")
        var lines = Array(text.utf8).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(
            Array.init
        )
        if lines.last == [] { lines.removeLast() }
        var index = 0
        var seen: Set<String> = []
        while index < lines.count, !lines[index].starts(with: Array("@@".utf8)) {
            guard
                let prefix = ["diff ", "index ", "--- ", "+++ "].first(where: {
                    lines[index].starts(with: Array($0.utf8))
                }),
                seen.insert(prefix).inserted
            else { return .failure(notDiff) }
            index += 1
        }
        var hunks: [Hunk] = []
        var added = 0
        var removed = 0
        while index < lines.count {
            let header = String(decoding: lines[index], as: UTF8.self)
            guard let oldStart = Self.oldStart(header) else {
                return .failure(
                    Problem(
                        description:
                            "hunk \(hunks.count + 1) has a bad header: \(DisplayText.summary(header, limit: 80))"
                    )
                )
            }
            index += 1
            var old: [[UInt8]] = []
            var new: [[UInt8]] = []
            var oldNoNewline = false
            var newNoNewline = false
            var last: UInt8?
            while index < lines.count, !lines[index].starts(with: Array("@@".utf8)) {
                let line = lines[index]
                let body = Array(line.dropFirst())
                switch line.first {
                case UInt8(ascii: " "), nil:
                    old.append(body)
                    new.append(body)
                case UInt8(ascii: "-"):
                    if line.starts(with: Array("--- ".utf8)), Self.isFileHeader(lines, at: index) {
                        return .failure(notDiff)
                    }
                    old.append(body)
                    removed += 1
                case UInt8(ascii: "+"):
                    new.append(body)
                    added += 1
                case UInt8(ascii: "\\"):
                    switch last {
                    case UInt8(ascii: "-"): oldNoNewline = true
                    case UInt8(ascii: "+"): newNoNewline = true
                    default:
                        oldNoNewline = true
                        newNoNewline = true
                    }
                default:
                    return .failure(notDiff)
                }
                if line.first != UInt8(ascii: "\\") { last = line.first ?? UInt8(ascii: " ") }
                index += 1
            }
            guard !old.isEmpty || !new.isEmpty else {
                return .failure(Problem(description: "hunk \(hunks.count + 1) is empty"))
            }
            hunks.append(
                Hunk(
                    oldStart: oldStart,
                    header: header,
                    old: old,
                    new: new,
                    oldNoNewline: oldNoNewline,
                    newNoNewline: newNoNewline
                )
            )
        }
        guard !hunks.isEmpty else { return .failure(notDiff) }
        return .success(UnifiedPatch(hunks: hunks, added: added, removed: removed))
    }

    /// A `--- ` line followed by a `+++ ` line is another file's header, not a removed line starting with "-- ".
    private static func isFileHeader(_ lines: [[UInt8]], at index: Int) -> Bool {
        index + 1 < lines.count && lines[index + 1].starts(with: Array("+++ ".utf8))
    }

    /// The old start line of `@@ -l[,s] +l[,s] @@…`, or `nil` if it is not such a header.
    static func oldStart(_ header: String) -> Int? {
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@@", parts[3].hasPrefix("@@"), parts[1].hasPrefix("-"),
            parts[2].hasPrefix("+")
        else { return nil }
        func range(_ text: Substring) -> Int? {
            let numbers = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(numbers.count), numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }),
                let start = Int(numbers[0]), start >= 0, numbers.count == 1 || Int(numbers[1]) != nil
            else { return nil }
            return start
        }
        guard let start = range(parts[1]), range(parts[2]) != nil else { return nil }
        return start
    }

    /// The file with every hunk applied, or why not. `original` must be UTF-8 text.
    public func apply(to original: [UInt8]) -> Result<[UInt8], Problem> {
        guard Array(String(decoding: original, as: UTF8.self).utf8) == original else {
            return .failure(Problem(description: "the file is not UTF-8 text; replace it with write_file"))
        }
        var lines = original.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Array.init)
        var endsWithNewline = true
        if lines.last == [] {
            lines.removeLast()
        } else {
            endsWithNewline = false
        }
        var result: [[UInt8]] = []
        var cursor = 0
        for (number, hunk) in hunks.enumerated() {
            let name = "hunk \(number + 1) (\(DisplayText.summary(hunk.header, limit: 60)))"
            // A header's start names the first old line; an insertion names the line it goes after.
            let hinted = hunk.old.isEmpty ? hunk.oldStart : max(hunk.oldStart - 1, 0)
            func matches(at position: Int) -> Bool {
                position >= cursor && position + hunk.old.count <= lines.count
                    && lines[position..<position + hunk.old.count].elementsEqual(hunk.old)
            }
            let position: Int
            if matches(at: hinted) {
                position = hinted
            } else {
                guard !hunk.old.isEmpty else {
                    return .failure(Problem(description: "\(name) inserts after line \(hunk.oldStart), past the end"))
                }
                let found = (cursor...max(cursor, lines.count - hunk.old.count)).filter(matches)
                guard found.count == 1 else {
                    return .failure(
                        Problem(
                            description: found.isEmpty
                                ? "\(name) does not match the file"
                                : "\(name) matches the file in \(found.count) places; add context lines"
                        )
                    )
                }
                position = found[0]
            }
            result += lines[cursor..<position]
            result += hunk.new
            cursor = position + hunk.old.count
            if cursor == lines.count {
                if hunk.newNoNewline {
                    endsWithNewline = false
                } else if hunk.oldNoNewline {
                    endsWithNewline = true
                }
            }
        }
        result += lines[cursor...]
        var bytes = Array(result.joined(separator: [UInt8(ascii: "\n")]))
        if endsWithNewline, !result.isEmpty { bytes.append(UInt8(ascii: "\n")) }
        guard bytes.count <= FileWrite.maxBytes else {
            return .failure(Problem(description: "the patched file would be larger than \(FileWrite.maxBytes) bytes"))
        }
        return .success(bytes)
    }
}
