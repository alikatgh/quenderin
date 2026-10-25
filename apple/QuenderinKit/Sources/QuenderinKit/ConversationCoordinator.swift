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
    public private(set) var pinnedModelID: String?
    private let restoreSelectedModel: (@MainActor (String, ChatPreparationContext) async throws -> ModelEntry)?

    /// The open conversation's id — drives the macOS sidebar's selection highlight.
    public var currentID: String? { manager.currentID }

    private let manager: ConversationManager
    /// Drafts follow conversation identity; the live composer object survives model-loading view removal.
    private var composerSnapshots: [String: ChatComposerState.Snapshot] = [:]

    /// How many of the live chat's messages are already saved for the CURRENT conversation.
    /// persist() only writes when the transcript grew past this — `save()` stamps `updatedAt`,
    /// and without the guard every conversation SWITCH (open / ⌘N / relaunch) re-stamped an
    /// untouched chat, so last night's conversation read "25 min ago" this morning.
    private var savedCount = 0

    public init(
        chat: ChatModel,
        persistence: ConversationPersistence,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        restoreSelectedModel: (@MainActor (String, ChatPreparationContext) async throws -> ModelEntry)? = nil
    ) {
        self.restoreSelectedModel = restoreSelectedModel
        self.chat = chat
        self.manager = ConversationManager(persistence: persistence, now: now)
        manager.pruneEmptyConversations()   // GC blank rows left by the old create-immediately startNew()
        manager.refreshPreviews()   // backfill snippets for indexes written before `preview` existed
        // Pick up where you left off: restore the most recent conversation, or start fresh.
        if let recent = manager.list().first {
            pinnedModelID = recent.automaticModelID
            chat.restore(manager.open(recent.id), hasOrdinaryInference: recent.hasOrdinaryInference)
            savedCount = chat.messages.count
        } else {
            manager.startNew()
        }
        chat.prepareRestoredModel = { [weak self] current, preparation in
            guard let self, let pin = self.pinnedModelID, let restore = self.restoreSelectedModel else { return current }
            let selected = try await restore(pin, preparation)
            guard preparation.isCurrent() else { throw CancellationError() }
            self.activeModelID = selected.id
            return selected
        }
        chat.didRecordGuidedTurn = { [weak self] in self?.persist() }
        chat.didAcceptModel = { [weak self] model, automaticSelected in
            guard let self, let model else { return }
            self.activeModelID = model.id
            if automaticSelected { self.pinnedModelID = model.id }
        }
        refresh()
    }

    public func chooseModelManually(_ id: String) {
        chat.invalidatePendingPreparation()
        activeModelID = id
        if pinnedModelID != nil {
            pinnedModelID = id
            if let current = manager.currentID { manager.updateAutomaticModelID(id: current, modelID: id) }
        }
        refresh()
    }

    private func refresh() { summaries = manager.list() }
    private func stashComposer() {
        guard let id = manager.currentID else { return }
        let snapshot = chat.composer.snapshot()
        if snapshot.isEmpty { composerSnapshots.removeValue(forKey: id) }
        else { composerSnapshots[id] = snapshot }
    }
    private func restoreComposer() {
        chat.composer.restore(manager.currentID.flatMap { composerSnapshots[$0] } ?? .init())
    }

    /// Persist the current conversation — call when a turn finishes. No-ops on an empty chat so
    /// untouched "New conversation" rows don't pile up, and when nothing new was said since the
    /// last save (see `savedCount`). Callers like `startNew()`/`open()` can run mid-stream (e.g.
    /// the user navigates away) — `chat.messages` then ends in a placeholder/partial assistant
    /// turn, which is trimmed before saving so the just-sent user message (and any prior
    /// completed turns) is still persisted instead of silently dropped.
    public func persist() {
        guard let id = manager.currentID, !chat.messages.isEmpty else { return }
        // Snapshot before stopping: a streaming send leaves an assistant placeholder/partial
        // reply in `messages`; save only completed turns and the user's message, matching the
        // Kotlin twin. Stop the reply as well so a conversation switch cannot leave a zombie
        // writer behind (Q-004/Q-168).
        var toSave = chat.messages
        let wasGenerating = chat.isGenerating
        if wasGenerating { chat.stopGenerating() }
        if wasGenerating, toSave.last?.role == .assistant {
            toSave.removeLast()
        }
        guard toSave.count > savedCount else { return }
        manager.save(id: id, messages: toSave, modelID: activeModelID,
                     automaticModelID: pinnedModelID, hasOrdinaryInference: chat.hasOrdinaryInference)
        savedCount = toSave.count
        refresh()
    }

    /// Start a fresh conversation. Saves the one you're leaving first; a no-op if the current
    /// chat is already empty (avoids stacking blank conversations).
    public func startNew() {
        defer { newChatSignal += 1 }   // even a storage no-op must surface the empty chat
        stashComposer()
        guard !chat.messages.isEmpty else {
            // Reuse the accessible empty conversation, including its draft, while invalidating
            // any asynchronous first-turn verification/load. No unsaved draft is stranded.
            chat.reset(); pinnedModelID = nil; savedCount = 0
            restoreComposer()
            return
        }
        persist()
        manager.startNew()
        chat.reset()
        pinnedModelID = nil
        savedCount = 0
        restoreComposer()
        refresh()
    }

    /// Open a past conversation into the chat, saving the current one first.
    public func open(_ id: String) {
        stashComposer()
        persist()
        let summary = manager.list().first(where: { $0.id == id })
        pinnedModelID = summary?.automaticModelID
        chat.restore(manager.open(id), hasOrdinaryInference: summary?.hasOrdinaryInference)
        restoreComposer()
        savedCount = chat.messages.count
        refresh()
    }

    /// Delete a conversation. If it was the open one, fall back to the most recent (or a fresh one).
    public func delete(_ id: String) {
        let wasCurrent = manager.currentID == id
        ChatPrefsStore.shared.clear(for: id)   // per-chat appearance overrides die with the chat
        manager.delete(id)
        composerSnapshots.removeValue(forKey: id)
        if wasCurrent {
            if let recent = manager.list().first {
                pinnedModelID = recent.automaticModelID
                chat.restore(manager.open(recent.id), hasOrdinaryInference: recent.hasOrdinaryInference)
                savedCount = chat.messages.count
            } else {
                manager.startNew()
                pinnedModelID = nil
                chat.reset()
                savedCount = 0
            }
            restoreComposer()
        }
        refresh()
    }

    /// Delete SEVERAL conversations in one operation (multi-select bulk delete): per-chat
    /// prefs die with each, and the current-chat fallback runs ONCE at the end — deleting
    /// five chats must not open and restore five intermediate conversations.
    public func deleteMany(_ ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        let deletingCurrent = manager.currentID.map(ids.contains) ?? false
        for id in ids {
            ChatPrefsStore.shared.clear(for: id)
            manager.delete(id)
            composerSnapshots.removeValue(forKey: id)
        }
        if deletingCurrent {
            if let recent = manager.list().first {
                pinnedModelID = recent.automaticModelID
                chat.restore(manager.open(recent.id), hasOrdinaryInference: recent.hasOrdinaryInference)
                savedCount = chat.messages.count
            } else {
                manager.startNew()
                pinnedModelID = nil
                chat.reset()
                savedCount = 0
            }
            restoreComposer()
        }
        refresh()
    }

    /// Delete all saved conversations, then drop into a fresh empty one (first-launch state).
    public func clearAll() {
        summaries.forEach { ChatPrefsStore.shared.clear(for: $0.id) }
        manager.clearAll()
        composerSnapshots.removeAll()
        manager.startNew()
        pinnedModelID = nil
        chat.reset()
        savedCount = 0
        restoreComposer()
        refresh()
    }
}
