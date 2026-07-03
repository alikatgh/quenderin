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
    /** One-line snippet of the LAST message ("You: …" for the user's own) — what a chat-list row
     *  shows under the title, WhatsApp-style. Empty for a conversation with no messages yet. */
    val preview: String = "",
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
         * A one-line list snippet from the LAST message: whitespace collapsed, truncated at 80
         * code points, prefixed "You: " when the last speaker was the user (twin of Swift
         * `preview(fromLastMessage:)`).
         */
        fun previewFromLastMessage(message: ChatMessage?): String {
            // A snippet is plain text: drop the Markdown markers an assistant reply carries
            // (bold/heading/code fences), or the row reads "**Python Knowledge** Here are…".
            val trimmed = message?.text
                ?.replace("**", "")?.replace("`", "")?.replace("#", "")
                ?.trim() ?: return ""
            if (trimmed.isEmpty()) return ""
            val collapsed = trimmed.split(Regex("\\s+")).joinToString(" ")
            val limit = 80
            val body = if (collapsed.codePointCount(0, collapsed.length) <= limit) {
                collapsed
            } else {
                collapsed.substring(0, collapsed.offsetByCodePoints(0, limit)) + "…"
            }
            return if (message.role == Role.USER) "You: $body" else body
        }

        /**
         * A short display title from the first user line: whitespace collapsed and truncated.
         * An empty conversation gets a generic label.
         */
        fun titleFromFirstUserMessage(text: String?): String {
            val trimmed = (text ?: "").trim()
            if (trimmed.isEmpty()) return "New conversation"
            val collapsed = trimmed.split(Regex("\\s+")).joinToString(" ")
            val limit = 40
            // Truncate by CODE POINTS, not UTF-16 units, so the cut matches iOS's scalar-based cut
            // exactly (cross-platform title parity) AND never lands mid-surrogate (a lone high
            // surrogate is invalid UTF-16 and can break Gson/Jackson). offsetByCodePoints handles both.
            if (collapsed.codePointCount(0, collapsed.length) <= limit) return collapsed
            val end = collapsed.offsetByCodePoints(0, limit)
            return collapsed.substring(0, end) + "…"
        }
    }
}
