import Foundation

/// One row in the chat-history list: which conversation, its display title, and when it was
/// last touched. The messages themselves live in a `ConversationStore` blob keyed by `id`,
/// so this index stays small and cheap to load.
public struct ConversationSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var updatedAt: Int64   // epoch milliseconds (supplied by the caller, not the clock)

    public init(id: String, title: String, updatedAt: Int64) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// The index behind a chat-history sidebar: the set of saved conversations, newest first.
/// Pure and deterministic (timestamps come from the caller), so it unit-tests with no app.
/// Same snapshot/restore shape as `DownloadStore`. Twin of Kotlin `ConversationLibrary`.
public final class ConversationLibrary {
    private var entries: [String: ConversationSummary] = [:]

    public init(_ snapshot: [ConversationSummary] = []) {
        for summary in snapshot { entries[summary.id] = summary }
    }

    /// Insert or update a summary (keyed by `id`).
    public func upsert(_ summary: ConversationSummary) {
        entries[summary.id] = summary
    }

    /// All conversations, most-recently-updated first; `id` breaks ties for stable ordering.
    public func list() -> [ConversationSummary] {
        entries.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
    }

    public func get(_ id: String) -> ConversationSummary? { entries[id] }

    @discardableResult
    public func remove(_ id: String) -> Bool { entries.removeValue(forKey: id) != nil }

    public var count: Int { entries.count }

    /// The full index, for the app to persist (mirrors `DownloadStore.snapshot`).
    public func snapshot() -> [ConversationSummary] { Array(entries.values) }

    /// A short display title from the first user line: whitespace collapsed and truncated.
    /// An empty conversation gets a generic label.
    public static func title(fromFirstUserMessage text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New conversation" }
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limit = 40
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
