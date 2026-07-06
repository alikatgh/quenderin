package ai.quenderin.core

enum class Role { USER, ASSISTANT }

/**
 * A document the user attached to a chat message — name for display, extracted text for the
 * model. Extraction happens AT ATTACH TIME (strict UTF-8, size-capped) so what the model sees is
 * fixed when the message is sent. Twin of iOS `AttachedDocument` (Milestone 1).
 */
data class AttachedDocument(val name: String, val text: String)

data class ChatMessage(
    val role: Role,
    val text: String,
    /** Documents attached to this (user) message. UI shows chips + typed text; [engineText] is
     *  what the model gets. */
    val documents: List<AttachedDocument> = emptyList(),
) {
    /** The text the ENGINE sees: labeled documents first, then the typed message. Composed into
     *  every windowed history pass so follow-ups keep the document in context. Twin of iOS. */
    val engineText: String
        get() {
            if (documents.isEmpty()) return text
            val docs = documents.joinToString("\n\n") { "Attached file \"${it.name}\":\n${it.text}" }
            return "$docs\n\n$text"
        }
}

/**
 * True when this is an assistant message whose text trips [SafetyBlocklist] — the chat UI surfaces
 * a non-blocking warning ([SupportContact.FLAGGED_OUTPUT_NOTICE]) rather than suppressing it, the
 * on-device "minimize risk" safeguard for the Generative-AI policies. User messages are never
 * flagged. Kept in parity with iOS `ChatMessage.isFlagged`.
 */
val ChatMessage.isFlagged: Boolean
    get() = role == Role.ASSISTANT && SafetyBlocklist.isBlocked(text)

/**
 * M2 chat brain: holds the transcript, sends a prompt to the [engine], appends the
 * reply. Dependency-free and listener-based ([onChange]) so it unit-tests on the JVM;
 * the Compose layer maps [onChange] into state and runs [send] off the main thread
 * (optionally via [LlamaEngine.complete]'s streaming overload for token-by-token UI).
 * Twin of Swift `ChatModel`.
 *
 * Concurrency contract (Android runs [send] on a background dispatcher, unlike iOS's single
 * `@MainActor`): the transcript is only ever mutated under [lock], and each streaming generation
 * carries a monotonic id ([activeGeneration]). A lifecycle op that changes the transcript from the
 * main thread — [reset]/[restore], driven by conversation switch/new/delete — first [stopGenerating]s
 * the in-flight send, which bumps the generation id and cancels the native decode. A still-running
 * (zombie) send then finds its id superseded and drops every remaining token/settle write, so tokens
 * from conversation A can never bleed into (or index out of bounds on) conversation B. `@Volatile` +
 * `synchronized(lock)` give the Compose main-thread reader a happens-before view of the writes, same
 * idiom as [AgentSession]. (Q-004/Q-168 corruption; Q-005/Q-237 stop + degeneration abort.)
 */
class ChatModel(
    private val engine: InferenceEngine,
    var onChange: (List<ChatMessage>) -> Unit = {},
    private val context: ConversationContext = ConversationContext(),
) {
    private val lock = Any()
    private val _messages = mutableListOf<ChatMessage>()
    val messages: List<ChatMessage> get() = synchronized(lock) { _messages.toList() }

    /** Monotonic id of the generation allowed to write the transcript. A send captures its id at start;
     *  [stopGenerating]/[reset]/[restore] bump this so a superseded (zombie) send stops writing. */
    @Volatile
    private var activeGeneration: Long = 0

    /** True while a [send] is streaming. Read on the main thread (Compose) to drive the Stop affordance;
     *  written under [lock]. Twin of iOS `ChatModel.isGenerating`. */
    @Volatile
    var isGenerating: Boolean = false
        private set

    private fun emit() = onChange(messages)

    /**
     * Appends the user's line, runs the engine over the whole transcript streaming into a placeholder
     * assistant message, settles the final text, and returns it. Blocking; the app calls it off the main
     * thread. Throws [EngineNotLoadedException] if no model is loaded (surfaced to the UI, never
     * swallowed). No-op (returns "") if a generation is already in flight — a rapid double-send can't
     * race two writers onto the transcript.
     */
    @JvmOverloads
    fun send(text: String, documents: List<AttachedDocument> = emptyList()): String {
        val trimmed = text.trim()
        // Documents alone are a legitimate send ("summarize this file" with no extra words). Twin-drift
        // fix: an empty send is a SILENT no-op (return ""), matching iOS ChatModel's `guard … else { return }`
        // — the old `require(...)` threw IllegalArgumentException, crashing the send coroutine on Android
        // while iOS ignored it, and it was inconsistent even with this file's own already-generating guard
        // (which returns "" too).
        if (trimmed.isEmpty() && documents.isEmpty()) return ""
        // The user line + placeholder assistant slot + this generation's id are established atomically
        // under the lock, so a concurrent reset/restore either happens fully before (this send sees the
        // new transcript) or fully after (it bumps our id and we drop our writes below), never
        // interleaved. Two emits (user, then placeholder) keep the UX where the user's bubble appears
        // immediately, then the "typing…" placeholder — the snapshots are taken inside the lock and
        // emitted outside it (a listener must never re-enter under the lock).
        val myGen: Long
        val placeholderIndex: Int
        val history: List<ChatMessage>
        val afterUser: List<ChatMessage>
        val afterPlaceholder: List<ChatMessage>
        synchronized(lock) {
            if (isGenerating) return ""
            isGenerating = true
            myGen = ++activeGeneration
            _messages += ChatMessage(Role.USER, trimmed, documents)
            afterUser = _messages.toList()
            // History is computed BEFORE the placeholder is appended so the empty assistant turn isn't
            // included in the prompt. Passed STRUCTURED so the engine formats with the model's own chat
            // template (early-stop + higher quality). Trimmed to the engine's REAL loaded n_ctx (often
            // 512–2048 on phones), not a hardcoded 4096 that would overflow the native window (Q-167).
            // Attached documents are composed in (engineText) BEFORE windowing so the budget counts them.
            history = context.windowedHistory(
                _messages.map { if (it.documents.isEmpty()) it else it.copy(text = it.engineText, documents = emptyList()) },
                engine.loadedContextTokens,
            )
            placeholderIndex = _messages.size
            _messages += ChatMessage(Role.ASSISTANT, "")
            afterPlaceholder = _messages.toList()
        }
        onChange(afterUser)
        onChange(afterPlaceholder)
        try {
            val sb = StringBuilder()
            var tokenCount = 0
            // Stream into the placeholder so the reply appears token-by-token instead of the UI sitting
            // blank for the whole (multi-second) generation. Mirrors iOS `ChatModel`.
            val reply = engine.completeChat(context.systemPrompt, history) { piece ->
                sb.append(piece)
                // Degeneration guard: if the tail is verbatim-looping despite the sampler's repetition
                // penalty, stop paying for tokens — the settle-time collapse below cleans up. Checked every
                // 32 tokens like iOS; asks the engine to end the native decode now. (Q-237)
                tokenCount += 1
                if (tokenCount % 32 == 0 && DegenerationGuard.looksDegenerate(sb.toString())) {
                    engine.requestCancel()
                }
                // Drop the write if this generation was superseded (conversation switch/new/reset/restore,
                // or Stop) — a captured index would otherwise write into the WRONG transcript or throw out
                // of bounds. Twin of iOS's "look the message up by id each token; if it's gone, stop".
                writeAssistant(myGen, placeholderIndex, sb.toString())
            }
            // Settle on the authoritative full text (covers the non-streaming fallback, where onToken never
            // fired and the placeholder is still empty) — with duplicate-paragraph runs collapsed
            // (DegenerationGuard; the sampler penalty upstream prevents most, this cleans the rest).
            val settled = DegenerationGuard.collapseRepeatedParagraphs(reply)
            // Q-588: never leave a silently EMPTY assistant bubble — an engine that produced zero tokens gets
            // an honest notice, mirroring iOS ChatModel. Only when this generation is still active: a user
            // Stop supersedes it (activeGeneration bumped), and then the streamed partial should stand,
            // exactly as iOS's `!stopRequested` guard. (writeAssistant also drops a superseded write.)
            val stillActive = synchronized(lock) { myGen == activeGeneration }
            val finalText = if (settled.isBlank() && stillActive) {
                "The model returned an empty reply. Try rephrasing, or pick a larger model in the Model library."
            } else {
                settled
            }
            writeAssistant(myGen, placeholderIndex, finalText)
            return finalText
        } finally {
            synchronized(lock) {
                // Only the CURRENT generation owns isGenerating; a superseded send must not clear a flag a
                // newer send/lifecycle op already re-set (M10 finally-safety, same as AgentSession).
                if (activeGeneration == myGen) isGenerating = false
            }
        }
    }

    /** Write the assistant placeholder iff this generation is still the active one and the slot is still
     *  in range — under [lock] so a concurrent [reset]/[restore] can't shrink the list between the check
     *  and the write. A superseded generation (or a cleared slot) drops the write silently. */
    private fun writeAssistant(gen: Long, index: Int, textValue: String) {
        val changed = synchronized(lock) {
            if (gen != activeGeneration || index >= _messages.size) return@synchronized false
            _messages[index] = ChatMessage(Role.ASSISTANT, textValue)
            true
        }
        if (changed) emit()
    }

    /**
     * Stop the in-flight reply where it is: bump the generation id so no more tokens land, and ask the
     * engine to interrupt its native decode now (the flag-only break lands one token late and does nothing
     * during a non-interruptible prefill — Q-005/Q-217). Idempotent; no-op when nothing is generating.
     * The streamed partial already in the transcript stays. Twin of iOS `ChatModel.stopGenerating`.
     */
    fun stopGenerating() {
        synchronized(lock) {
            if (!isGenerating) return
            activeGeneration++   // supersede the running send → its remaining writes become no-ops
            isGenerating = false
        }
        engine.requestCancel()
    }

    /** Clear the conversation. First stops any in-flight generation so a zombie send can't write into the
     *  now-empty transcript (out of bounds) or resurrect a stale reply. */
    fun reset() {
        stopGenerating()
        synchronized(lock) { _messages.clear() }
        emit()
    }

    /** Replace the transcript with a previously persisted conversation (see [ConversationStore]),
     *  so a chat picks up exactly where it left off after a relaunch. First stops any in-flight
     *  generation so tokens from the OUTGOING conversation can't bleed into the one being restored
     *  (the conversation-switch corruption — Q-004/Q-168). */
    fun restore(saved: List<ChatMessage>) {
        stopGenerating()
        synchronized(lock) {
            _messages.clear()
            _messages.addAll(saved)
        }
        emit()
    }
}
