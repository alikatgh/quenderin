import Foundation

/// One row in the chat-history list: which conversation, its display title, and when it was
/// last touched. The messages themselves live in a `ConversationStore` blob keyed by `id`,
/// so this index stays small and cheap to load.
public struct ConversationSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var updatedAt: Int64   // epoch milliseconds (supplied by the caller, not the clock)
    /// One-line snippet of the LAST message ("You: …" for the user's own) — what a chat-list row
    /// shows under the title, WhatsApp-style. Empty for a conversation with no messages yet.
    public var preview: String
    /// The catalog id of the model that last answered in this conversation — lets list rows wear
    /// that family's avatar. `nil` for rows saved before the field existed (brand orb fallback).
    public var modelID: String?

    public init(id: String, title: String, updatedAt: Int64, preview: String = "", modelID: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
        self.modelID = modelID
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

    /// A one-line list snippet from the LAST message: whitespace collapsed, truncated at 80 code
    /// points, prefixed "You: " when the last speaker was the user (twin of Kotlin `preview`).
    public static func preview(fromLastMessage message: ChatMessage?) -> String {
        guard let message else { return "" }
        // A snippet is plain text: drop the Markdown markers an assistant reply carries
        // (bold/heading/code fences), or the row reads "**Python Knowledge** Here are…".
        let plain = message.text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let scalars = Array(collapsed.unicodeScalars)
        let limit = 80
        let body = scalars.count > limit
            ? String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
            : collapsed
        return message.role == .user ? "You: \(body)" : body
    }

    /// A short display title from the first user line: whitespace collapsed and truncated.
    /// An empty conversation gets a generic label.
    public static func title(fromFirstUserMessage text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New conversation" }
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limit = 40
        // Truncate by Unicode scalar (code point), NOT grapheme — so the cut matches Kotlin's
        // code-point cut (offsetByCodePoints) exactly. Swift's default `.count`/`.prefix` is
        // grapheme-based and would truncate an emoji/CJK title at a different point than Android's
        // UTF-16 `substring`, breaking the cross-platform title parity. (Both never split a scalar.)
        let scalars = Array(collapsed.unicodeScalars)
        guard scalars.count > limit else { return collapsed }
        return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
    }
}
