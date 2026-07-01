import Foundation
import Combine

/// Binds `ConversationManager` (pure lifecycle) to a live `ChatModel` and a SwiftUI list. Owns
/// the chat for the history feature: on launch it restores the most recent conversation (or
/// starts a fresh one), persists after each completed turn, and drives start-new / open / delete.
/// The view layer observes `summaries` for the history list and `chat` for the transcript.
@MainActor
public final class ConversationCoordinator: ObservableObject {
    /// History rows, newest first — drives the history list.
    @Published public private(set) var summaries: [ConversationSummary] = []

    /// The live chat for the *current* conversation.
    public let chat: ChatModel

    private let manager: ConversationManager

    public init(
        chat: ChatModel,
        persistence: ConversationPersistence,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.chat = chat
        self.manager = ConversationManager(persistence: persistence, now: now)
        // Pick up where you left off: restore the most recent conversation, or start fresh.
        if let recent = manager.list().first {
            chat.restore(manager.open(recent.id))
        } else {
            manager.startNew()
        }
        refresh()
    }

    private func refresh() { summaries = manager.list() }

    /// Persist the current conversation — call when a turn finishes. No-ops on an empty chat so
    /// untouched "New conversation" rows don't pile up, and while a reply is still streaming —
    /// `chat.messages` ends in a placeholder/partial assistant turn until `send()` completes, and
    /// callers like `startNew()`/`open()` can run mid-stream (e.g. the user navigates away).
    public func persist() {
        guard let id = manager.currentID, !chat.messages.isEmpty, !chat.isGenerating else { return }
        manager.save(id: id, messages: chat.messages)
        refresh()
    }

    /// Start a fresh conversation. Saves the one you're leaving first; a no-op if the current
    /// chat is already empty (avoids stacking blank conversations).
    public func startNew() {
        guard !chat.messages.isEmpty else { return }
        persist()
        manager.startNew()
        chat.reset()
        refresh()
    }

    /// Open a past conversation into the chat, saving the current one first.
    public func open(_ id: String) {
        persist()
        chat.restore(manager.open(id))
        refresh()
    }

    /// Delete a conversation. If it was the open one, fall back to the most recent (or a fresh one).
    public func delete(_ id: String) {
        let wasCurrent = manager.currentID == id
        manager.delete(id)
        if wasCurrent {
            if let recent = manager.list().first {
                chat.restore(manager.open(recent.id))
            } else {
                manager.startNew()
                chat.reset()
            }
        }
        refresh()
    }

    /// Delete all saved conversations, then drop into a fresh empty one (first-launch state).
    public func clearAll() {
        manager.clearAll()
        manager.startNew()
        chat.reset()
        refresh()
    }
}
