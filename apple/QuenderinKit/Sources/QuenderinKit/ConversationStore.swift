import Foundation

/// Persists a chat transcript so a conversation survives app relaunch — the offline-first
/// promise made concrete: your history lives on-device, never on a server. Pure
/// serialization to/from a `Data` blob; the app writes that blob to a file, so the actual
/// I/O stays at the edge (the same shape as `DownloadStore`'s snapshot/restore). Twin of
/// Kotlin `ConversationStore`.
public struct ConversationStore: Sendable {
    public init() {}

    /// Encode a transcript to a portable blob.
    public func encode(_ messages: [ChatMessage]) throws -> Data {
        try JSONEncoder().encode(messages.map(StoredMessage.init))
    }

    /// Decode a transcript from a blob; an empty/missing blob is an empty conversation,
    /// not an error (first launch, or a cleared chat).
    public func decode(_ data: Data) throws -> [ChatMessage] {
        guard !data.isEmpty else { return [] }
        // Drop rows with an unparseable role rather than coercing to `.assistant` — coercing
        // would silently relabel the speaker and replay it as "Assistant:" into
        // `ConversationContext.build()` on the next turn. Matches Kotlin `ConversationStore`,
        // which drops the same row via `mapNotNull`.
        return try JSONDecoder().decode([StoredMessage].self, from: data).compactMap(\.chatMessage)
    }

    /// On-disk shape — role + text only. Message ids are *view* identity, regenerated on
    /// load, not content; decoupling the wire format from `ChatMessage` lets the model
    /// evolve without breaking saved files.
    private struct StoredMessage: Codable {
        let role: String
        let text: String

        init(_ message: ChatMessage) {
            role = message.role.rawValue
            text = message.text
        }

        var chatMessage: ChatMessage? {
            ChatMessage.Role(rawValue: role).map { ChatMessage(role: $0, text: text) }
        }
    }
}
