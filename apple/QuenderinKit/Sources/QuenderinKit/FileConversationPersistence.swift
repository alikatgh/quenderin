import Foundation

/// File-backed `ConversationPersistence`: each transcript is a `ConversationStore` blob, plus a
/// small JSON index of summaries, under a directory the app owns (Application Support by
/// default). The on-disk edge for `ConversationManager` — pure file I/O, so it's unit-testable
/// against a temp directory. Twin of Android `FileConversationPersistence`.
public final class FileConversationPersistence: ConversationPersistence {
    private let dir: URL
    private let store = ConversationStore()

    /// - Parameter directory: where to keep transcripts + the index (created if needed).
    ///   Defaults to `<Application Support>/conversations`; tests pass a temp dir.
    public init(directory: URL? = nil) {
        self.dir = directory ?? FileConversationPersistence.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("conversations", isDirectory: true)
    }

    // ids are UUID strings (no path separators); take the last path component as a defensive
    // guard so a hostile id can never escape the directory.
    private func transcriptURL(_ id: String) -> URL {
        dir.appendingPathComponent((id as NSString).lastPathComponent + ".json")
    }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    public func saveTranscript(id: String, messages: [ChatMessage]) {
        guard let data = try? store.encode(messages) else { return }
        try? data.write(to: transcriptURL(id), options: .atomic)
    }

    public func loadTranscript(id: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: transcriptURL(id)) else { return [] }
        return (try? store.decode(data)) ?? []
    }

    public func deleteTranscript(id: String) {
        try? FileManager.default.removeItem(at: transcriptURL(id))
    }

    public func saveIndex(_ summaries: [ConversationSummary]) {
        let rows = summaries.map { IndexRow(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    public func loadIndex() -> [ConversationSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let rows = try? JSONDecoder().decode([IndexRow].self, from: data) else { return [] }
        return rows.map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    /// On-disk index shape — Codable mirror of `ConversationSummary` (which stays a plain value
    /// type in the core), the same decoupling `ConversationStore.StoredMessage` uses.
    private struct IndexRow: Codable {
        let id: String
        let title: String
        let updatedAt: Int64
    }
}
