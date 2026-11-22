import Crypto
import Foundation

/// What an audit entry records.
public enum AuditEvent: String, Sendable, Codable {
    /// The engine decided a request.
    case decision
    /// The owner approved an asked request.
    case ownerApproved
    /// The owner denied an asked request.
    case ownerDenied
    /// An asked request was denied because the owner did not answer in time.
    case approvalTimedOut
    /// The owner added a project allow rule.
    case ruleAdded
    /// The owner removed a project allow rule.
    case ruleRemoved
    /// The owner changed a setting, such as the approval timeout.
    case settingsChanged
    /// The app started a session; the detail says whether the previous log verified.
    case sessionStarted
    /// The approval mode changed.
    case modeChanged
    /// The baton moved.
    case baton
    /// The owner pressed Stop.
    case stopped
    /// The owner reset after Stop.
    case reset
    /// The session folder changed.
    case scopeChanged
    /// The sandbox self-test ran; the detail says whether it passed.
    case sandboxChecked
    /// The app is about to run an allowed or approved action. Nothing runs unless this entry was persisted.
    case starting
    /// The app ran an allowed or approved action; the detail says whether it worked, with a command's exit
    /// status and output size (never the output).
    case executed
    /// A serial session was closed: by Claude, Stop or a new session folder.
    case serialClosed
    /// The ESP-IDF environment was derived for an approved or allowed flasher, as part of it; the detail names the
    /// install and whether it can be used.
    case idfEnvironment
    /// An `esp_idf_install` was copied into the owner's toolchain folder, or a toolchain failed its check; the
    /// detail names the install and its hash, or why not.
    case toolchain
    /// The owner installed Claude Code, or started it in the shared terminal from the window (D11); the detail names
    /// the version and the install's hash, or why not.
    case claudeCode
    /// A `git_commit` was queued for the owner's review, or the owner pushed or dismissed a queued branch (D11).
    case review
    /// A connection through the gatekeeper proxy: the attempt and its decision, and, for an allowed one, how it
    /// ended (bytes each way, duration).
    case network
}

/// Position at the end of a chain: entries so far and the last entry's hash.
public struct AuditHead: Sendable, Equatable, Codable {
    /// Number of entries; also the next sequence number.
    public var count: Int
    /// SHA-256 (hex) of the last entry, or 64 zeros for an empty log.
    public var hash: String

    /// Creates a head.
    public init(count: Int, hash: String) {
        self.count = count
        self.hash = hash
    }

    /// The head of an empty log.
    public static let genesis = AuditHead(count: 0, hash: String(repeating: "0", count: 64))
}

/// Result of verifying a log.
public enum AuditVerification: Sendable, Equatable {
    /// Every line is intact and correctly chained.
    case valid(AuditHead)
    /// The first bad line (zero-based) and why.
    case invalid(line: Int, reason: String)
}

/// Produces and verifies a hash-chained, append-only JSONL audit log. Only builds lines; the app writes them.
///
/// Each line is canonical JSON (sorted keys) holding `prevHash` and its own `hash`, the SHA-256 of the entry without
/// `hash`. Edits, deletions and reordering break the chain. Dropping lines from the end cannot be seen from the
/// lines alone, so the app must keep the latest `head` somewhere the agent user cannot write and compare.
public struct AuditLog: Sendable {
    /// Position after the last appended entry.
    public private(set) var head: AuditHead

    /// Starts a new log, or continues one from a verified head.
    public init(head: AuditHead = .genesis) {
        self.head = head
    }

    /// Appends an entry and returns its JSONL line (no trailing newline).
    public mutating func append(
        _ event: AuditEvent,
        request: ActionRequest? = nil,
        decision: Decision? = nil,
        detail: String? = nil,
        at time: Date
    ) throws -> String {
        var entry = Entry(
            seq: head.count,
            ts: Self.timestamp(time),
            prevHash: head.hash,
            event: event,
            detail: detail,
            request: request,
            decision: decision
        )
        entry.hash = try Self.digest(of: entry)
        let line = try Self.encode(entry)
        head = AuditHead(count: head.count + 1, hash: entry.hash ?? "")
        return line
    }

    /// Verifies lines in order, from the start of the log.
    public static func verify(_ lines: [String]) -> AuditVerification {
        var head = AuditHead.genesis
        for (index, line) in lines.enumerated() {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), let hash = entry.hash
            else {
                return .invalid(line: index, reason: "not an audit entry")
            }
            guard entry.seq == head.count else {
                return .invalid(line: index, reason: "sequence \(entry.seq), expected \(head.count)")
            }
            guard entry.prevHash == head.hash else {
                return .invalid(line: index, reason: "does not follow the previous entry")
            }
            guard (try? digest(of: entry)) == hash, (try? encode(entry)) == line else {
                return .invalid(line: index, reason: "content does not match its hash")
            }
            head = AuditHead(count: head.count + 1, hash: hash)
        }
        return .valid(head)
    }

    struct Entry: Codable {
        var seq: Int
        var ts: String
        var prevHash: String
        var event: AuditEvent
        var detail: String?
        var request: ActionRequest?
        var decision: Decision?
        var hash: String?
    }

    static func encode(_ entry: Entry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    static func digest(of entry: Entry) throws -> String {
        var unsigned = entry
        unsigned.hash = nil
        let digest = SHA256.hash(data: Data(try encode(unsigned).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
