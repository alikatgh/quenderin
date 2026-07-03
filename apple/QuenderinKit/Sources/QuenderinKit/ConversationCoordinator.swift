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

    /// Bumped on EVERY `startNew()` call — including the no-op case where the current chat is
    /// already empty. Shells observe it to move selection/focus to the (possibly reused) current
    /// conversation, so "New Chat" is never a dead button (e.g. pressed from the Agent pane, or
    /// pressed twice — the second press must still land you in the empty chat, ready to type).
    @Published public private(set) var newChatSignal = 0

    /// The live chat for the *current* conversation.
    public let chat: ChatModel

    /// The catalog id of the ACTIVE model — stamped onto each conversation at save time so its
    /// list row wears that family's avatar. The shell keeps this current across model switches.
    public var activeModelID: String?

    /// The open conversation's id — drives the macOS sidebar's selection highlight.
    public var currentID: String? { manager.currentID }

    private let manager: ConversationManager

    /// How many of the live chat's messages are already saved for the CURRENT conversation.
    /// persist() only writes when the transcript grew past this — `save()` stamps `updatedAt`,
    /// and without the guard every conversation SWITCH (open / ⌘N / relaunch) re-stamped an
    /// untouched chat, so last night's conversation read "25 min ago" this morning.
    private var savedCount = 0

    public init(
        chat: ChatModel,
        persistence: ConversationPersistence,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.chat = chat
        self.manager = ConversationManager(persistence: persistence, now: now)
        manager.pruneEmptyConversations()   // GC blank rows left by the old create-immediately startNew()
        manager.refreshPreviews()   // backfill snippets for indexes written before `preview` existed
        // Pick up where you left off: restore the most recent conversation, or start fresh.
        if let recent = manager.list().first {
            chat.restore(manager.open(recent.id))
            savedCount = chat.messages.count
        } else {
            manager.startNew()
        }
        refresh()
    }

    private func refresh() { summaries = manager.list() }

    /// Persist the current conversation — call when a turn finishes. No-ops on an empty chat so
    /// untouched "New conversation" rows don't pile up, while a reply is still streaming —
    /// `chat.messages` ends in a placeholder/partial assistant turn until `send()` completes, and
    /// callers like `startNew()`/`open()` can run mid-stream (e.g. the user navigates away) —
    /// and when nothing new was said since the last save (see `savedCount`).
    public func persist() {
        guard let id = manager.currentID, !chat.messages.isEmpty, !chat.isGenerating,
              chat.messages.count > savedCount else { return }
        manager.save(id: id, messages: chat.messages, modelID: activeModelID)
        savedCount = chat.messages.count
        refresh()
    }

    /// Start a fresh conversation. Saves the one you're leaving first; a no-op if the current
    /// chat is already empty (avoids stacking blank conversations).
    public func startNew() {
        defer { newChatSignal += 1 }   // even a storage no-op must surface the empty chat
        guard !chat.messages.isEmpty else { return }
        persist()
        manager.startNew()
        chat.reset()
        savedCount = 0
        refresh()
    }

    /// Open a past conversation into the chat, saving the current one first.
    public func open(_ id: String) {
        persist()
        chat.restore(manager.open(id))
        savedCount = chat.messages.count
        refresh()
    }

    /// Delete a conversation. If it was the open one, fall back to the most recent (or a fresh one).
    public func delete(_ id: String) {
        let wasCurrent = manager.currentID == id
        manager.delete(id)
        if wasCurrent {
            if let recent = manager.list().first {
                chat.restore(manager.open(recent.id))
                savedCount = chat.messages.count
            } else {
                manager.startNew()
                chat.reset()
                savedCount = 0
            }
        }
        refresh()
    }

    /// Delete all saved conversations, then drop into a fresh empty one (first-launch state).
    public func clearAll() {
        manager.clearAll()
        manager.startNew()
        chat.reset()
        savedCount = 0
        refresh()
    }
}
