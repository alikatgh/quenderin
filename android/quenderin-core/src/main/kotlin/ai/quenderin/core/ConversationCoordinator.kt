package ai.quenderin.core

import java.util.UUID

data class ConversationDraft(val text: String = "", val documents: List<AttachedDocument> = emptyList())

/**
 * Binds [ConversationManager] (pure lifecycle) to a live [ChatModel] for the history feature: on
 * construction it restores the most recent conversation (or starts fresh), persists after each
 * completed turn, and drives start-new / open / delete. Listener-based ([onChange]) so the Compose
 * layer maps `summaries` into state; unit-tests on the JVM. Twin of Swift `ConversationCoordinator`.
 */
class ConversationCoordinator(
    val chat: ChatModel,
    persistence: ConversationPersistence,
    now: () -> Long = { System.currentTimeMillis() },
    makeId: () -> String = { UUID.randomUUID().toString() },
    var onChange: (List<ConversationSummary>) -> Unit = {},
) {
    private val manager = ConversationManager(persistence, now, makeId)
    private val drafts = HashMap<String, ConversationDraft>()
    fun draft(id: String?): ConversationDraft = synchronized(drafts) { drafts[id] ?: ConversationDraft() }
    fun saveDraft(id: String?, text: String, documents: List<AttachedDocument>) {
        if (id == null) return
        synchronized(drafts) { if (text.isEmpty() && documents.isEmpty()) drafts.remove(id) else drafts[id] = ConversationDraft(text, documents.toList()) }
    }
    fun draftAfterCancelledAdmission(id: String?, revision: Long, messageCountBeforeSend: Int): ConversationDraft? =
        if (id == currentId && revision == lifecycleRevision && chat.messages.size == messageCountBeforeSend) draft(id) else null

    /** History rows, newest first. */
    var summaries: List<ConversationSummary> = emptyList()
        private set

    /** The open conversation's id (twin of Swift `currentID`). */
    val currentId: String? get() = manager.currentId
    val pinnedLocalModelID: String? get() = manager.currentLocalModelID
    val hasOrdinaryTurn: Boolean get() = manager.currentHasOrdinaryTurn
    @Volatile var lifecycleRevision: Long = 0L
        private set
    fun pinLocalModel(modelID: String) = manager.pinLocalModel(modelID)
    fun recordLocalAdmission(modelID: String, automatic: Boolean, expectedID: String?) = manager.recordLocalAdmission(modelID, automatic, expectedID)

    /**
     * How many of the live chat's messages are already saved for the CURRENT conversation.
     * [persist] only writes when the transcript grew past this — `save()` stamps `updatedAt`,
     * and without the guard every conversation SWITCH (open / new / relaunch) re-stamped an
     * untouched chat, faking recency in the history list. (Twin of the Swift coordinator.)
     */
    private var savedCount = 0

    init {
        manager.pruneEmptyConversations()   // GC blank rows left by the old create-immediately startNew()
        manager.refreshPreviews()   // backfill snippets for indexes written before `preview` existed
        // Pick up where you left off: restore the most recent conversation, or start fresh.
        val recent = manager.list().firstOrNull()
        if (recent != null) {
            chat.restore(manager.open(recent.id))
            savedCount = chat.messages.size
        } else {
            manager.startNew()
        }
        refresh()
    }

    private fun refresh() {
        summaries = manager.list()
        onChange(summaries)
    }

    /** Persist the current conversation — call when a turn finishes. No-op on an empty chat so
     *  untouched "New conversation" rows don't pile up, and when nothing new was said since the
     *  last save (see [savedCount]). */
    fun persist() {
        // Stop any in-flight reply BEFORE snapshotting: persist() runs on a conversation switch/back, and
        // saving a half-streamed transcript (or letting the zombie send keep writing into it after this
        // conversation is left) is the corruption this guards. reset()/restore() also stop, so every
        // lifecycle path that mutates the chat is now preceded by a stop. (Q-004/Q-168.)
        chat.stopGenerating()
        val id = manager.currentId ?: return
        if (chat.messages.isEmpty() || chat.messages.size <= savedCount) return
        manager.save(id, chat.messages)
        savedCount = chat.messages.size
        refresh()
    }
    fun persistIfOwned(id: String?, revision: Long, ownsJob: () -> Boolean): Boolean {
        if (id != currentId || revision != lifecycleRevision || !ownsJob()) return false
        persist()
        return true
    }
    fun finishOwnedSend(id: String?, revision: Long, ownsJob: () -> Boolean, clearOwner: () -> Unit) {
        try { persistIfOwned(id, revision, ownsJob) }
        finally { if (ownsJob()) clearOwner() }
    }

    /** Start a fresh conversation (saving the one you're leaving). No-op if the chat is empty. */
    fun startNew() {
        lifecycleRevision++
        chat.invalidatePreparedTurns()
        if (chat.messages.isEmpty()) return // Keep the existing empty draft reachable; only its pending send is invalidated.
        persist()
        manager.startNew()
        chat.reset()
        savedCount = 0
        refresh()
    }

    /** Open a past conversation into the chat, saving the current one first. */
    fun open(id: String) {
        lifecycleRevision++
        chat.invalidatePreparedTurns()
        persist()
        chat.restore(manager.open(id))
        savedCount = chat.messages.size
        refresh()
    }

    /** Delete a conversation. If it was the open one, fall back to the most recent (or fresh). */
    fun delete(id: String) {
        lifecycleRevision++
        chat.invalidatePreparedTurns()
        val wasCurrent = manager.currentId == id
        manager.delete(id)
        synchronized(drafts) { drafts.remove(id) }
        if (wasCurrent) {
            val recent = manager.list().firstOrNull()
            if (recent != null) {
                chat.restore(manager.open(recent.id))
                savedCount = chat.messages.size
            } else {
                manager.startNew(); chat.reset(); savedCount = 0
            }
        }
        refresh()
    }

    /** Delete all saved conversations, then drop into a fresh empty one (first-launch state). */
    fun clearAll() {
        lifecycleRevision++
        chat.invalidatePreparedTurns()
        manager.clearAll()
        synchronized(drafts) { drafts.clear() }
        manager.startNew()
        chat.reset()
        savedCount = 0
        refresh()
    }
}
