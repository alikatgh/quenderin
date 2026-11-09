package ai.quenderin.core

/**
 * One live writer per conversation, adapted from Turnstone's workstream owner.
 *
 * A second writer does not append. Only the live permit can release the
 * conversation. After its lifetime, a new writer may replace a crashed one.
 * Releasing a stale permit leaves the newer owner in place.
 */
data class WriterPermit(
    val conversationId: String,
    val writerId: String,
    val token: String,
    val expiresAtMs: Long,
)

sealed interface WriterClaim {
    data class Granted(val permit: WriterPermit) : WriterClaim
    data class Busy(val ownerId: String, val message: String) : WriterClaim
}

class ConversationWriter {
    private val owners = HashMap<String, WriterPermit>()
    private var nonce = 0
    private val lock = Any()

    fun claim(conversationId: String, writerId: String, nowMs: Long, ttlMs: Long): WriterClaim {
        val conversation = conversationId.trim()
        val writer = writerId.trim()
        if (conversation.isEmpty() || writer.isEmpty()) return WriterClaim.Busy("", ID_MESSAGE)
        if (ttlMs <= 0) return WriterClaim.Busy("", TTL_MESSAGE)
        return synchronized(lock) {
            val current = owners[conversation]
            if (current != null && nowMs < current.expiresAtMs) {
                WriterClaim.Busy(current.writerId, busyMessage(current.writerId))
            } else {
                val permit = WriterPermit(conversation, writer, (++nonce).toString(), nowMs + ttlMs)
                owners[conversation] = permit
                WriterClaim.Granted(permit)
            }
        }
    }

    /** True only when this permit is still the live owner. */
    @Suppress("UNUSED_PARAMETER")
    fun release(permit: WriterPermit, nowMs: Long): Boolean = synchronized(lock) {
        val current = owners[permit.conversationId]
        if (current == null || current.token != permit.token) false
        else {
            owners.remove(permit.conversationId)
            true
        }
    }

    companion object {
        val shared = ConversationWriter()
        const val ID_MESSAGE = "A conversation writer needs a conversation and a writer."
        const val TTL_MESSAGE = "A conversation writer needs a positive lifetime."
        fun busyMessage(ownerId: String) =
            "This conversation already has a live reply from \"$ownerId\". Wait for it to finish."
    }
}
