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

    init {
        // Pick up where you left off: restore the most recent conversation, or start fresh.
        val recent = manager.list().firstOrNull()
        if (recent != null) chat.restore(manager.open(recent.id)) else manager.startNew()
        refresh()
    }

    private fun refresh() {
        summaries = manager.list()
        onChange(summaries)
    }

    /** Persist the current conversation — call when a turn finishes. No-op on an empty chat so
     *  untouched "New conversation" rows don't pile up. */
    fun persist() {
        val id = manager.currentId ?: return
        if (chat.messages.isEmpty()) return
        manager.save(id, chat.messages)
        refresh()
    }

    /** Start a fresh conversation (saving the one you're leaving). No-op if the chat is empty. */
    fun startNew() {
        if (chat.messages.isEmpty()) return
        persist()
        manager.startNew()
        chat.reset()
        refresh()
    }

    /** Open a past conversation into the chat, saving the current one first. */
    fun open(id: String) {
        persist()
        chat.restore(manager.open(id))
        refresh()
    }

    /** Delete a conversation. If it was the open one, fall back to the most recent (or fresh). */
    fun delete(id: String) {
        val wasCurrent = manager.currentId == id
        manager.delete(id)
        if (wasCurrent) {
            val recent = manager.list().firstOrNull()
            if (recent != null) chat.restore(manager.open(recent.id)) else { manager.startNew(); chat.reset() }
        }
        refresh()
    }

    /** Delete all saved conversations, then drop into a fresh empty one (first-launch state). */
    fun clearAll() {
        manager.clearAll()
        manager.startNew()
        chat.reset()
        refresh()
    }
}
