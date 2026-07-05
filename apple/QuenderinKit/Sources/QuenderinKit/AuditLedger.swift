import Foundation

/// One row of the agent's action ledger — what ran (or was refused), when, and what it touched.
/// The ledger is the user's flight recorder for autonomy (AGENT_AUTONOMY_PLAN §3.6): every
/// capability invocation is recorded, including the refused ones. Append-only by design.
public struct AuditEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let capability: String
    public let tier: Int
    /// The input, truncated — the ledger explains actions; it is not a transcript store.
    public let input: String
    /// "allowed" | "blocked(<keyword>)" | "needsConsent" | "error"
    public let decision: String
    /// Truncated result/error when the capability actually ran; nil when it was refused.
    public let outcome: String?

    public init(timestamp: Date, capability: String, tier: Int, input: String, decision: String, outcome: String?) {
        self.timestamp = timestamp
        self.capability = capability
        self.tier = tier
        self.input = String(input.prefix(200))
        self.decision = decision
        self.outcome = outcome.map { String($0.prefix(200)) }
    }
}

/// Where audit entries go. Implementations must be safe to call from the agent's async context.
public protocol AuditLedger: Sendable {
    func append(_ entry: AuditEntry)
    func entries() -> [AuditEntry]
}

/// Test/default ledger — keeps entries in memory (lock-protected).
public final class InMemoryAuditLedger: AuditLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AuditEntry] = []

    public init() {}

    public func append(_ entry: AuditEntry) {
        lock.lock(); defer { lock.unlock() }
        stored.append(entry)
    }

    public func entries() -> [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// The real ledger: one JSON object per line (JSONL), appended to a file the user can open.
/// JSONL because append-only means a crash can at worst truncate the LAST line — every prior
/// action survives, and `entries()` skips a torn tail instead of losing the whole log.
public final class FileAuditLedger: AuditLedger, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Default location: `<Application Support>/Quenderin/agent-ledger.jsonl`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Quenderin/agent-ledger.jsonl")
    }

    public init(url: URL = FileAuditLedger.defaultURL()) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ entry: AuditEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? encoder.encode(entry) else { return }
        let line = data + Data("\n".utf8)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // The ledger must never take the agent down — but a silent ledger is a lying ledger,
            // so at least leave a trace for diagnosis (same rule as persistence Q-009).
            print("[AuditLedger] append failed: \(error.localizedDescription)")
        }
    }

    public func entries() -> [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(AuditEntry.self, from: Data($0)) }
    }
}
