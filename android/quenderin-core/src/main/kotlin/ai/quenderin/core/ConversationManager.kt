package ai.quenderin.core

/**
 * Where a [ConversationManager] reads and writes — per-id transcripts and the history index.
 * Abstracted so the manager stays pure and testable; the app supplies a file-backed
 * implementation (mapping these calls onto [ConversationStore] + `filesDir`), while tests and
 * previews use [InMemoryConversationPersistence].
 */
interface ConversationPersistence {
    fun saveTranscript(id: String, messages: List<ChatMessage>)
    fun loadTranscript(id: String): List<ChatMessage>
    fun deleteTranscript(id: String)
    fun saveIndex(summaries: List<ConversationSummary>)
    fun loadIndex(): List<ConversationSummary>
}

/** In-memory persistence for tests and previews; the file-backed impl lives in the app layer. */
class InMemoryConversationPersistence : ConversationPersistence {
    private val transcripts = HashMap<String, List<ChatMessage>>()
    private var index: List<ConversationSummary> = emptyList()

    override fun saveTranscript(id: String, messages: List<ChatMessage>) { transcripts[id] = messages }
    override fun loadTranscript(id: String): List<ChatMessage> = transcripts[id] ?: emptyList()
    override fun deleteTranscript(id: String) { transcripts.remove(id) }
    override fun saveIndex(summaries: List<ConversationSummary>) { index = summaries }
    override fun loadIndex(): List<ConversationSummary> = index
}

/**
 * The capstone that turns the chat-memory pieces into one feature: it owns the conversation
 * lifecycle — create, auto-title, persist-on-save, list (history), open, delete — over a
 * [ConversationLibrary] index and a [ConversationPersistence] backend. Pure and deterministic
 * (clock + id generator injected), so it unit-tests with no app and no real clock. The app
 * glues it to [ChatModel] (startNew → reset, open → restore, after each turn → save). Twin of
 * Swift `ConversationManager`.
 */
class ConversationManager(
    private val persistence: ConversationPersistence,
    private val now: () -> Long,
    private val makeId: () -> String,
) {
    private val library = ConversationLibrary(persistence.loadIndex())

    var currentId: String? = null
        private set

    /** The history list, newest first. */
    fun list(): List<ConversationSummary> = library.list()

    /**
     * Begin a fresh, empty conversation and make it current. Deliberately writes NOTHING:
     * the index row and transcript are created by the first [save], so a new chat the user
     * abandons without typing never leaves a blank "New conversation" row in the history
     * list (WhatsApp only creates a list row on the first message).
     */
    fun startNew(): String {
        val id = makeId()
        currentId = id
        return id
    }

    /**
     * Persist a conversation: refresh its title from the first user line, stamp `updatedAt`,
     * and write the transcript + index. Call after each turn with the chat's messages.
     */
    fun save(id: String, messages: List<ChatMessage>) {
        val firstUser = messages.firstOrNull { it.role == Role.USER }?.text
        library.upsert(ConversationSummary(
            id,
            ConversationLibrary.titleFromFirstUserMessage(firstUser),
            now(),
            preview = ConversationLibrary.previewFromLastMessage(messages.lastOrNull()),
        ))
        persistence.saveTranscript(id, messages)
        persistence.saveIndex(library.snapshot())
    }

    /** One-time cleanup for indexes written by the old [startNew] (which created the row and
     *  saved immediately): drop every summary whose transcript is empty — those are abandoned
     *  "New conversation" shells, not history. Run before restoring the most recent conversation
     *  so a blank shell is never what launch reopens. */
    fun pruneEmptyConversations() {
        var changed = false
        for (summary in library.list()) {
            if (persistence.loadTranscript(summary.id).isEmpty()) {
                library.remove(summary.id)
                persistence.deleteTranscript(summary.id)
                changed = true
            }
        }
        if (changed) persistence.saveIndex(library.snapshot())
    }

    /** One-time backfill for indexes written before `preview` existed: compute each snippet from
     *  its transcript WITHOUT touching `updatedAt` — this is repair, not activity. */
    fun refreshPreviews() {
        var changed = false
        for (summary in library.list()) {
            if (summary.preview.isNotEmpty()) continue
            val preview = ConversationLibrary.previewFromLastMessage(persistence.loadTranscript(summary.id).lastOrNull())
            if (preview.isNotEmpty()) {
                library.upsert(summary.copy(preview = preview))
                changed = true
            }
        }
        if (changed) persistence.saveIndex(library.snapshot())
    }

    /** Load a conversation's transcript and make it current (seed it into [ChatModel.restore]). */
    fun open(id: String): List<ChatMessage> {
        currentId = id
        return persistence.loadTranscript(id)
    }

    /** Delete a conversation everywhere. If it was the open one, nothing is current afterward. */
    fun delete(id: String) {
        library.remove(id)
        persistence.deleteTranscript(id)
        persistence.saveIndex(library.snapshot())
        if (currentId == id) currentId = null
    }

    /** Delete every conversation (all transcripts + the index). Nothing is current afterward. */
    fun clearAll() {
        library.snapshot().forEach { persistence.deleteTranscript(it.id); library.remove(it.id) }
        persistence.saveIndex(library.snapshot())   // now empty
        currentId = null
    }
}
