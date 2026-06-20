import Foundation

/// Where a `ConversationManager` reads and writes — per-id transcripts and the history index.
/// Abstracted so the manager stays pure and testable; the app supplies a file-backed
/// implementation (e.g. `ConversationStore` blobs under Documents), while tests and SwiftUI
/// previews use `InMemoryConversationPersistence`.
public protocol ConversationPersistence: AnyObject {
    func saveTranscript(id: String, messages: [ChatMessage])
    func loadTranscript(id: String) -> [ChatMessage]
    func deleteTranscript(id: String)
    func saveIndex(_ summaries: [ConversationSummary])
    func loadIndex() -> [ConversationSummary]
}

/// In-memory persistence for tests and previews. The file-backed implementation lives in the
/// app layer (it just maps these calls onto `ConversationStore` + a directory).
public final class InMemoryConversationPersistence: ConversationPersistence {
    private var transcripts: [String: [ChatMessage]] = [:]
    private var index: [ConversationSummary] = []

    public init() {}

    public func saveTranscript(id: String, messages: [ChatMessage]) { transcripts[id] = messages }
    public func loadTranscript(id: String) -> [ChatMessage] { transcripts[id] ?? [] }
    public func deleteTranscript(id: String) { transcripts[id] = nil }
    public func saveIndex(_ summaries: [ConversationSummary]) { index = summaries }
    public func loadIndex() -> [ConversationSummary] { index }
}

/// The capstone that turns the chat-memory pieces into one feature: it owns the conversation
/// lifecycle — create, auto-title, persist-on-save, list (history), open, delete — over a
/// `ConversationLibrary` index and a `ConversationPersistence` backend. Pure and
/// deterministic: the clock and id generator are injected, so it unit-tests with no app and
/// no real clock. The app glues it to `ChatModel` (startNew → reset, open → restore, after
/// each turn → save). Twin of Kotlin `ConversationManager`.
public final class ConversationManager {
    private let persistence: ConversationPersistence
    private let now: () -> Int64
    private let makeID: () -> String
    private let library: ConversationLibrary
    public private(set) var currentID: String?

    public init(
        persistence: ConversationPersistence,
        now: @escaping () -> Int64,
        makeID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.persistence = persistence
        self.now = now
        self.makeID = makeID
        self.library = ConversationLibrary(persistence.loadIndex())
    }

    /// The history list, newest first.
    public func list() -> [ConversationSummary] { library.list() }

    /// Begin a fresh, empty conversation and make it current.
    @discardableResult
    public func startNew() -> String {
        let id = makeID()
        currentID = id
        library.upsert(ConversationSummary(id: id, title: "New conversation", updatedAt: now()))
        persistence.saveTranscript(id: id, messages: [])
        persistence.saveIndex(library.snapshot())
        return id
    }

    /// Persist a conversation: refresh its title from the first user line, stamp `updatedAt`,
    /// and write the transcript + index. Call after each turn with the chat's messages.
    public func save(id: String, messages: [ChatMessage]) {
        let firstUser = messages.first(where: { $0.role == .user })?.text
        library.upsert(ConversationSummary(
            id: id,
            title: ConversationLibrary.title(fromFirstUserMessage: firstUser),
            updatedAt: now()
        ))
        persistence.saveTranscript(id: id, messages: messages)
        persistence.saveIndex(library.snapshot())
    }

    /// Load a conversation's transcript and make it current (seed it into `ChatModel.restore`).
    public func open(_ id: String) -> [ChatMessage] {
        currentID = id
        return persistence.loadTranscript(id: id)
    }

    /// Delete a conversation everywhere. If it was the open one, nothing is current afterward.
    public func delete(_ id: String) {
        library.remove(id)
        persistence.deleteTranscript(id: id)
        persistence.saveIndex(library.snapshot())
        if currentID == id { currentID = nil }
    }

    /// Delete every conversation (all transcripts + the index). Nothing is current afterward.
    public func clearAll() {
        for summary in library.snapshot() {
            persistence.deleteTranscript(id: summary.id)
            library.remove(summary.id)
        }
        persistence.saveIndex(library.snapshot())   // now empty
        currentID = nil
    }
}
