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
    private val indexState = Any()
    private var writingIndex = false
    private var indexDirty = false

    /** Coalesce concurrent index updates under one existing caller. A lifecycle action can update
     * memory while an older saveIndex is blocked; the writer then drains the latest snapshot. */
    private fun persistIndex() {
        synchronized(indexState) { indexDirty = true; if (writingIndex) return; writingIndex = true }
        try {
            while (true) {
                val snapshot = synchronized(indexState) { indexDirty = false; library.snapshot() }
                persistence.saveIndex(snapshot)
                val again = synchronized(indexState) { if (indexDirty) true else { writingIndex = false; false } }
                if (!again) return
            }
        } catch (error: Throwable) { synchronized(indexState) { writingIndex = false }; throw error }
    }

    @Volatile var currentId: String? = null
        private set
    @Volatile var currentLocalModelID: String? = null
        private set
    @Volatile var currentHasOrdinaryTurn: Boolean = false
        private set
    fun pinLocalModel(modelID: String) {
        require(InferencePerformanceIdentity.validModelID(modelID))
        recordLocalAdmission(modelID, automatic = true, expectedID = currentId)
    }
    fun recordLocalAdmission(modelID: String, automatic: Boolean, expectedID: String?) {
        require(InferencePerformanceIdentity.validModelID(modelID))
        val id = expectedID ?: return
        val changed = synchronized(indexState) {
            if (currentId == id) { currentLocalModelID = modelID.takeIf { automatic }; currentHasOrdinaryTurn = true }
            library.get(id)?.let { library.upsert(it.copy(localModelID = modelID.takeIf { automatic }, hasOrdinaryTurn = true,
                automaticModelPin = automatic)); true } ?: false
        }
        if (changed) persistIndex()
    }

    /** The history list, newest first. */
    fun list(): List<ConversationSummary> = synchronized(indexState) { library.list() }

    /**
     * Begin a fresh, empty conversation and make it current. Deliberately writes NOTHING:
     * the index row and transcript are created by the first [save], so a new chat the user
     * abandons without typing never leaves a blank "New conversation" row in the history
     * list (WhatsApp only creates a list row on the first message).
     */
    fun startNew(): String {
        val id = makeId()
        synchronized(indexState) { currentId = id; currentLocalModelID = null; currentHasOrdinaryTurn = false }
        return id
    }

    /**
     * Persist a conversation: refresh its title from the first user line, stamp `updatedAt`,
     * and write the transcript + index. Call after each turn with the chat's messages.
     */
    fun save(id: String, messages: List<ChatMessage>) {
        val firstUser = messages.firstOrNull { it.role == Role.USER }?.text
        synchronized(indexState) { library.upsert(ConversationSummary(
            id,
            ConversationLibrary.titleFromFirstUserMessage(firstUser),
            now(),
            preview = ConversationLibrary.previewFromLastMessage(messages.lastOrNull()),
            localModelID = if (id == currentId) currentLocalModelID else library.get(id)?.localModelID,
            hasOrdinaryTurn = if (id == currentId) currentHasOrdinaryTurn else library.get(id)?.hasOrdinaryTurn ?: false,
            automaticModelPin = if (id == currentId) currentLocalModelID != null else library.get(id)?.automaticModelPin ?: false,
        )) }
        persistence.saveTranscript(id, messages)
        persistIndex()
    }

    /** One-time cleanup for indexes written by the old [startNew] (which created the row and
     *  saved immediately): drop every summary whose transcript is empty — those are abandoned
     *  "New conversation" shells, not history. Run before restoring the most recent conversation
     *  so a blank shell is never what launch reopens. */
    fun pruneEmptyConversations() {
        var changed = false
        for (summary in list()) {
            if (persistence.loadTranscript(summary.id).isEmpty()) {
                synchronized(indexState) { library.remove(summary.id) }
                persistence.deleteTranscript(summary.id)
                changed = true
            }
        }
        if (changed) persistIndex()
    }

    /** One-time backfill for indexes written before `preview` existed: compute each snippet from
     *  its transcript WITHOUT touching `updatedAt` — this is repair, not activity. */
    fun refreshPreviews() {
        var changed = false
        for (summary in list()) {
            if (summary.preview.isNotEmpty()) continue
            val preview = ConversationLibrary.previewFromLastMessage(persistence.loadTranscript(summary.id).lastOrNull())
            if (preview.isNotEmpty()) {
                synchronized(indexState) { library.upsert(summary.copy(preview = preview)) }
                changed = true
            }
        }
        if (changed) persistIndex()
    }

    /** Load a conversation's transcript and make it current (seed it into [ChatModel.restore]). */
    fun open(id: String): List<ChatMessage> {
        synchronized(indexState) {
            currentId = id
            currentLocalModelID = library.get(id)?.takeIf { it.automaticModelPin }?.localModelID
            currentHasOrdinaryTurn = library.get(id)?.hasOrdinaryTurn ?: false
        }
        return persistence.loadTranscript(id)
    }

    /** Delete a conversation everywhere. If it was the open one, nothing is current afterward. */
    fun delete(id: String) {
        synchronized(indexState) { library.remove(id)
            if (currentId == id) { currentId = null; currentLocalModelID = null; currentHasOrdinaryTurn = false }
        }
        persistence.deleteTranscript(id)
        persistIndex()
    }

    /** Delete every conversation (all transcripts + the index). Nothing is current afterward. */
    fun clearAll() {
        val snapshot = synchronized(indexState) {
            val rows = library.snapshot(); rows.forEach { library.remove(it.id) }
            currentId = null; currentLocalModelID = null; currentHasOrdinaryTurn = false; rows
        }
        snapshot.forEach { persistence.deleteTranscript(it.id) }
        persistIndex()
    }
}
