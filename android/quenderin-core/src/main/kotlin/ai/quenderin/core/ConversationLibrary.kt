package ai.quenderin.core

/**
 * One row in the chat-history list: which conversation, its display title, and when it was
 * last touched. The messages themselves live in a [ConversationStore] blob keyed by [id],
 * so this index stays small and cheap to load.
 */
data class ConversationSummary(
    val id: String,
    val title: String,
    val updatedAt: Long, // epoch milliseconds (supplied by the caller, not the clock)
)

/**
 * The index behind a chat-history sidebar: the set of saved conversations, newest first.
 * Pure and deterministic (timestamps come from the caller), so it unit-tests on the JVM with
 * no app. Same snapshot/restore shape as [DownloadStore]. Twin of Swift `ConversationLibrary`.
 */
class ConversationLibrary(snapshot: List<ConversationSummary> = emptyList()) {
    private val entries = LinkedHashMap<String, ConversationSummary>()

    init {
        snapshot.forEach { entries[it.id] = it }
    }

    /** Insert or update a summary (keyed by [ConversationSummary.id]). */
    fun upsert(summary: ConversationSummary) {
        entries[summary.id] = summary
    }

    /** All conversations, most-recently-updated first; id breaks ties for stable ordering. */
    fun list(): List<ConversationSummary> =
        entries.values.sortedWith(
            compareByDescending<ConversationSummary> { it.updatedAt }.thenBy { it.id },
        )

    fun get(id: String): ConversationSummary? = entries[id]

    fun remove(id: String): Boolean = entries.remove(id) != null

    val count: Int get() = entries.size

    /** The full index, for the app to persist (mirrors [DownloadStore.snapshot]). */
    fun snapshot(): List<ConversationSummary> = entries.values.toList()

    companion object {
        /**
         * A short display title from the first user line: whitespace collapsed and truncated.
         * An empty conversation gets a generic label.
         */
        fun titleFromFirstUserMessage(text: String?): String {
            val trimmed = (text ?: "").trim()
            if (trimmed.isEmpty()) return "New conversation"
            val collapsed = trimmed.split(Regex("\\s+")).joinToString(" ")
            val limit = 40
            return if (collapsed.length <= limit) collapsed else collapsed.substring(0, limit) + "…"
        }
    }
}
