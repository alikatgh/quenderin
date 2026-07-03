package ai.quenderin.core

import java.util.UUID

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

    /** History rows, newest first. */
    var summaries: List<ConversationSummary> = emptyList()
        private set

    /** The open conversation's id (twin of Swift `currentID`). */
    val currentId: String? get() = manager.currentId

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
        val id = manager.currentId ?: return
        if (chat.messages.isEmpty() || chat.messages.size <= savedCount) return
        manager.save(id, chat.messages)
        savedCount = chat.messages.size
        refresh()
    }

    /** Start a fresh conversation (saving the one you're leaving). No-op if the chat is empty. */
    fun startNew() {
        if (chat.messages.isEmpty()) return
        persist()
        manager.startNew()
        chat.reset()
        savedCount = 0
        refresh()
    }

    /** Open a past conversation into the chat, saving the current one first. */
    fun open(id: String) {
        persist()
        chat.restore(manager.open(id))
        savedCount = chat.messages.size
        refresh()
    }

    /** Delete a conversation. If it was the open one, fall back to the most recent (or fresh). */
    fun delete(id: String) {
        val wasCurrent = manager.currentId == id
        manager.delete(id)
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
        manager.clearAll()
        manager.startNew()
        chat.reset()
        savedCount = 0
        refresh()
    }
}
