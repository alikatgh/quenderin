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

    /** Begin a fresh, empty conversation and make it current. */
    fun startNew(): String {
        val id = makeId()
        currentId = id
        library.upsert(ConversationSummary(id, "New conversation", now()))
        persistence.saveTranscript(id, emptyList())
        persistence.saveIndex(library.snapshot())
        return id
    }

    /**
     * Persist a conversation: refresh its title from the first user line, stamp `updatedAt`,
     * and write the transcript + index. Call after each turn with the chat's messages.
     */
    fun save(id: String, messages: List<ChatMessage>) {
        val firstUser = messages.firstOrNull { it.role == Role.USER }?.text
        library.upsert(ConversationSummary(id, ConversationLibrary.titleFromFirstUserMessage(firstUser), now()))
        persistence.saveTranscript(id, messages)
        persistence.saveIndex(library.snapshot())
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
