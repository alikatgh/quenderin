import Foundation
import os

/// File-backed `ConversationPersistence`: each transcript is a `ConversationStore` blob, plus a
/// small JSON index of summaries, under a directory the app owns (Application Support by
/// default). The on-disk edge for `ConversationManager` — pure file I/O, so it's unit-testable
/// against a temp directory. Twin of Android `FileConversationPersistence`.
public final class FileConversationPersistence: ConversationPersistence {
    private let dir: URL
    private let store = ConversationStore()
    private static let log = Logger(subsystem: "org.quenderin", category: "persistence")

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
        do {
            let data = try store.encode(messages)
            try data.write(to: transcriptURL(id), options: .atomic)
        } catch {
            // A silent `try?` here loses chat history with no trace (Q-009). Surface it: the disk
            // is full, the volume is read-only, or encoding failed — the user needs to know their
            // transcript didn't persist, and a log entry makes it diagnosable in the field.
            Self.log.error("saveTranscript(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadTranscript(id: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: transcriptURL(id)) else { return [] }
        return (try? store.decode(data)) ?? []
    }

    public func deleteTranscript(id: String) {
        try? FileManager.default.removeItem(at: transcriptURL(id))
    }

    public func saveIndex(_ summaries: [ConversationSummary]) {
        let rows = summaries.map { IndexRow(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, preview: $0.preview, modelID: $0.modelID) }
        do {
            let data = try JSONEncoder().encode(rows)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Don't swallow: a lost index orphans transcripts from the history list (Q-009).
            Self.log.error("saveIndex failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadIndex() -> [ConversationSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let rows = try? JSONDecoder().decode([IndexRow].self, from: data) else { return [] }
        return rows.map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, preview: $0.preview ?? "", modelID: $0.modelID) }
    }

    /// On-disk index shape — Codable mirror of `ConversationSummary` (which stays a plain value
    /// type in the core), the same decoupling `ConversationStore.StoredMessage` uses.
    /// `preview` / `modelID` are optional so an index written before the fields existed still decodes.
    private struct IndexRow: Codable {
        let id: String
        let title: String
        let updatedAt: Int64
        let preview: String?
        let modelID: String?
    }
}
