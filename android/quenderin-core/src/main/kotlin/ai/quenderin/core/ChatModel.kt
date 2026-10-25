package ai.quenderin.core

enum class Role { USER, ASSISTANT }

/** Where generation is in its lifecycle — twin of iOS `GenerationPhase`. */
enum class GenerationPhase {
    IDLE,
    /** Engine processing the prompt; no tokens yet (can take seconds on phones). */
    LOADING_PROMPT,
    /** First token arrived; reply is streaming. */
    WRITING,
}

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
    /** Stable per-message identity for UI list keys. Assigned at construction and PRESERVED by
     *  copy(), so streaming — which copies the growing assistant message every token
     *  ([ChatModel.writeAssistant]) — keeps one stable key per row (no re-animation on each token),
     *  while a future non-append mutation (delete/regenerate/trim) still identifies each surviving
     *  row correctly. Not persisted; only needs to be stable within a UI session. Twin of iOS
     *  `ChatMessage.id`, which the streaming loop already looks messages up by. */
    val id: Long = nextId(),
) {
    /** The text the ENGINE sees: labeled documents first, then the typed message. Composed into
     *  every windowed history pass so follow-ups keep the document in context. Twin of iOS. */
    val engineText: String
        get() {
            if (documents.isEmpty()) return text
            val docs = documents.joinToString("\n\n") { "Attached file \"${it.name}\":\n${it.text}" }
            return "$docs\n\n$text"
        }

    companion object {
        private val idCounter = java.util.concurrent.atomic.AtomicLong(0L)
        private fun nextId(): Long = idCounter.incrementAndGet()
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
data class ChatTurnAdmission internal constructor(internal val revision: Long, internal val isCurrent: () -> Boolean)

class ChatModel(
    private val engine: InferenceEngine,
    var onChange: (List<ChatMessage>) -> Unit = {},
    private val context: ConversationContext = ConversationContext(),
) {
    fun <T> withSelectedModel(expectedID: String, action: () -> T): T = engine.withLoadedModel(expectedID, action)
    fun pendingChatFits(model: ModelEntry, request: AutomaticChatRequest): Boolean = engine.pendingChatFits(model, request)
    fun captureTurnAdmission(isCurrent: () -> Boolean = { true }): ChatTurnAdmission = synchronized(lock) { ChatTurnAdmission(activeGeneration, isCurrent) }
    fun isRevisionCurrent(revision: Long): Boolean = synchronized(lock) { activeGeneration == revision }
    private val lock = Any()
    private val _messages = mutableListOf<ChatMessage>()
    val messages: List<ChatMessage> get() = synchronized(lock) { _messages.toList() }

    /**
     * Id of the assistant message owned by a send whose turn has NOT settled yet. While it is set,
     * [completedMessages] excludes it and lifecycle invalidation removes it, so a partial reply that
     * the user navigated away from can never be persisted as a finished turn. Cleared by a normal
     * settle, by an explicit [stopGenerating] (the streamed partial is then the user's answer), and
     * by [invalidatePreparedTurns]/[reset]/[restore].
     */
    private var inFlightAssistantId: Long? = null

    /** Monotonic id of the generation allowed to write the transcript. A send captures its id at start;
     *  [stopGenerating]/[reset]/[restore] bump this so a superseded (zombie) send stops writing. */
    @Volatile
    private var activeGeneration: Long = 0

    /** True while a [send] is streaming. Read on the main thread (Compose) to drive the Stop affordance;
     *  written under [lock]. Twin of iOS `ChatModel.isGenerating`. */
    @Volatile
    var isGenerating: Boolean = false
        private set

    /**
     * Prefill vs decode — UI shows "Loading prompt…" until the first token, then "Writing…".
     * Twin of iOS `ChatModel.generationPhase`.
     */
    @Volatile
    var generationPhase: GenerationPhase = GenerationPhase.IDLE
        private set

    /**
     * True when the last settled reply stopped because it hit the engine's token cap mid-stream
     * (not Stop, not EOG). The UI surfaces a "Continue" affordance so the user can extend the
     * answer instead of staring at a mid-sentence cut. Twin of iOS `ChatModel.lastHitTokenCap`.
     * Cleared on the next [send] / [reset] / [restore].
     */
    @Volatile
    var lastHitTokenCap: Boolean = false
        private set

    /** Optional listener for phase flips (Compose polls [generationPhase] or rebinds here). */
    var onPhaseChange: (GenerationPhase) -> Unit = {}
    /** UI dispatchers must validate the revision when consuming a queued event. */
    var onRevisionChange: ((Long, List<ChatMessage>) -> Unit)? = null
    var onRevisionPhaseChange: ((Long, GenerationPhase) -> Unit)? = null

    private fun publish(revision: Long, snapshot: List<ChatMessage>) {
        if (!isRevisionCurrent(revision)) return
        onChange(snapshot)
        if (isRevisionCurrent(revision)) onRevisionChange?.invoke(revision, snapshot)
    }
    private fun publishPhase(revision: Long, phase: GenerationPhase) {
        val accepted = synchronized(lock) { if (activeGeneration != revision) false else { generationPhase = phase; true } }
        if (!accepted) return
        onPhaseChange(phase)
        if (isRevisionCurrent(revision)) onRevisionPhaseChange?.invoke(revision, phase)
    }

    /**
     * Record a user turn + a fixed assistant reply without calling the model. Used when chat
     * detects a computer task ([ActionIntent]) so the user gets education + a handoff button
     * instead of a generated "I cannot fulfill that request" wall. Twin of iOS
     * `ChatModel.recordGuidedTurn`.
     */
    fun recordGuidedTurn(
        userText: String,
        documents: List<AttachedDocument> = emptyList(),
        assistantText: String,
    ) {
        val trimmed = userText.trim()
        if ((trimmed.isEmpty() && documents.isEmpty()) || isGenerating) return
        val revision: Long
        val snapshot: List<ChatMessage>
        synchronized(lock) {
            if (isGenerating) return
            revision = ++activeGeneration
            _messages += ChatMessage(Role.USER, trimmed, documents)
            _messages += ChatMessage(Role.ASSISTANT, assistantText)
            snapshot = _messages.toList()
        }
        publish(revision, snapshot)
    }

    /**
     * Appends the user's line, runs the engine over the whole transcript streaming into a placeholder
     * assistant message, settles the final text, and returns it. Blocking; the app calls it off the main
     * thread. Throws [EngineNotLoadedException] if no model is loaded (surfaced to the UI, never
     * swallowed). No-op (returns "") if a generation is already in flight — a rapid double-send can't
     * race two writers onto the transcript.
     */
    @JvmOverloads
    fun send(text: String, documents: List<AttachedDocument> = emptyList(), model: ModelEntry? = null,
             admission: ChatTurnAdmission? = null, onAdmitted: (() -> Unit)? = null): String {
        val trimmed = text.trim()
        // Documents alone are a legitimate send ("summarize this file" with no extra words). Twin-drift
        // fix: an empty send is a SILENT no-op (return ""), matching iOS ChatModel's `guard … else { return }`
        // — the old `require(...)` threw IllegalArgumentException, crashing the send coroutine on Android
        // while iOS ignored it, and it was inconsistent even with this file's own already-generating guard
        // (which returns "" too).
        if (trimmed.isEmpty() && documents.isEmpty()) return ""
        val tier = ChatTier.of(model)
        val systemPrompt = tier.systemPrompt
        // Cap decode for tiny models (LlamaEngine honors chatMaxTokensOverride).
        engine.setChatTokenBudget(tier.maxTokens)
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
            if (admission != null && (admission.revision != activeGeneration || !admission.isCurrent())) throw AutomaticSelectionChangedException()
            if (isGenerating) return ""
            isGenerating = true
            myGen = ++activeGeneration
            generationPhase = GenerationPhase.LOADING_PROMPT
            lastHitTokenCap = false
            _messages += ChatMessage(Role.USER, trimmed, documents)
            afterUser = _messages.toList()
            // History is computed BEFORE the placeholder is appended so the empty assistant turn isn't
            // included in the prompt. Passed STRUCTURED so the engine formats with the model's own chat
            // template (early-stop + higher quality). Trimmed to the engine's REAL loaded n_ctx (often
            // 512–2048 on phones), not a hardcoded 4096 that would overflow the native window (Q-167).
            // Attached documents are composed in (engineText) BEFORE windowing so the budget counts them.
            val budgetCtx = ConversationContext(
                systemPrompt = systemPrompt,
                contextTokens = context.contextTokens,
                reservedForResponse = context.reservedForResponse,
            )
            history = budgetCtx.windowedHistory(
                _messages.map { if (it.documents.isEmpty()) it else it.copy(text = it.engineText, documents = emptyList()) },
                engine.loadedContextTokens,
            )
            placeholderIndex = _messages.size
            val placeholder = ChatMessage(Role.ASSISTANT, "")
            _messages += placeholder
            inFlightAssistantId = placeholder.id
            afterPlaceholder = _messages.toList()
        }
        publishPhase(myGen, GenerationPhase.LOADING_PROMPT)
        publish(myGen, afterUser)
        publish(myGen, afterPlaceholder)
        fun ownsGeneration(): Boolean = isRevisionCurrent(myGen) && (admission?.isCurrent?.invoke() != false)
        try {
            onAdmitted?.invoke() // May persist index metadata; lifecycle/reset never waits on this I/O.
            if (!ownsGeneration()) return ""
            val sb = StringBuilder()
            var tokenCount = 0
            // Pace transcript writes to display frames (~30 Hz): every write copies the list, re-parses
            // the reply's Markdown and hops to the main thread — at phone token rates that, not the
            // engine, is the jank. First piece always lands; the settle write below always lands.
            val flushGate = StreamFlushGate()
            // Stream into the placeholder so the reply appears token-by-token instead of the UI sitting
            // blank for the whole (multi-second) generation. Mirrors iOS `ChatModel`.
            val reply = engine.completeChatOwned(systemPrompt, history, ::ownsGeneration) { piece ->
                if (!ownsGeneration()) { engine.requestCancel(); return@completeChatOwned }
                sb.append(piece)
                // Degeneration guard: if the tail is verbatim-looping despite the sampler's repetition
                // penalty, stop paying for tokens — the settle-time collapse below cleans up. Checked every
                // 32 tokens like iOS; asks the engine to end the native decode now. (Q-237)
                tokenCount += 1
                if (tokenCount == 1) publishPhase(myGen, GenerationPhase.WRITING)
                if (tokenCount % 32 == 0 && DegenerationGuard.looksDegenerate(sb.toString())) {
                    engine.requestCancel()
                }
                // Drop the write if this generation was superseded (conversation switch/new/reset/restore,
                // or Stop) — a captured index would otherwise write into the WRONG transcript or throw out
                // of bounds. Twin of iOS's "look the message up by id each token; if it's gone, stop".
                if (flushGate.shouldFlush()) writeAssistant(myGen, placeholderIndex, sb.toString())
            }
            // Settle on the authoritative full text (covers the non-streaming fallback, where onToken never
            // fired and the placeholder is still empty) — with duplicate-paragraph runs collapsed
            // (DegenerationGuard; the sampler penalty upstream prevents most, this cleans the rest).
            val settled = DegenerationGuard.collapseRepeatedParagraphs(reply)
            // Q-588: never leave a silently EMPTY assistant bubble — an engine that produced zero tokens gets
            // an honest notice, mirroring iOS ChatModel. Only when this generation is still active: a user
            // Stop supersedes it (activeGeneration bumped), and then the streamed partial should stand,
            // exactly as iOS's `!stopRequested` guard. (writeAssistant also drops a superseded write.)
            val stillActive = ownsGeneration()
            val finalText = if (settled.isBlank() && stillActive) {
                // Locale-aware notice (ru/ko/ja/zh); default EN for tests / unknown locales.
                ChatUserFacing.emptyReply(java.util.Locale.getDefault().language)
            } else {
                settled
            }
            // Token-cap hit mid-sentence → "Continue" affordance (KNOWN_FAILURE_MODES). Real signal from
            // the native loop (perfDecodeTok >= maxTokens), not a piece count (UTF-8 reassembly merges
            // pieces so a piece-count would undercount). User Stop supersedes → stillActive false.
            if (stillActive) {
                val hitCap = engine.lastHitTokenCap()
                synchronized(lock) { if (myGen == activeGeneration) lastHitTokenCap = hitCap }
            }
            if (stillActive) writeAssistant(myGen, placeholderIndex, finalText)
            // Normal settle: this turn is now a finished answer. A Stop/abandon already cleared the
            // id (and a superseded send must not touch state a newer turn owns).
            synchronized(lock) { if (myGen == activeGeneration) inFlightAssistantId = null }
            return finalText
        } finally {
            val finished = synchronized(lock) {
                // Only the CURRENT generation owns isGenerating; a superseded send must not clear a flag a
                // newer send/lifecycle op already re-set (M10 finally-safety, same as AgentSession).
                if (activeGeneration == myGen) {
                    isGenerating = false
                    true
                } else false
            }
            if (finished) publishPhase(myGen, GenerationPhase.IDLE)
        }
    }

    /**
     * Extend the previous reply after a token-cap stop. Sends a short "continue" user turn so the
     * model picks up mid-thought. No-op when [lastHitTokenCap] is false (nothing was truncated).
     */
    fun continueLast(): String {
        if (!lastHitTokenCap || isGenerating) return ""
        return send(ChatUserFacing.continueCue(java.util.Locale.getDefault().language))
    }

    /** Write the assistant placeholder iff this generation is still the active one and the slot is still
     *  in range — under [lock] so a concurrent [reset]/[restore] can't shrink the list between the check
     *  and the write. A superseded generation (or a cleared slot) drops the write silently. */
    private fun writeAssistant(gen: Long, index: Int, textValue: String) {
        val snapshot = synchronized(lock) {
            if (gen != activeGeneration || index >= _messages.size) return@synchronized null
            // copy() (not a fresh ChatMessage) so the row keeps its stable [ChatMessage.id] across
            // every streamed token — the UI list key stays put instead of churning per token.
            _messages[index] = _messages[index].copy(text = textValue)
            _messages.toList()
        }
        if (snapshot != null) publish(gen, snapshot)
    }

    /**
     * Messages that belong to SETTLED turns — the only transcript a caller may persist. While a
     * reply streams, its assistant message is excluded (an engine that throws mid-stream leaves the
     * partial excluded too); after an explicit Stop the id is already cleared, so the partial is the
     * user's answer and is included. Twin of Swift `ChatModel.completedMessages`.
     */
    fun completedMessages(): List<ChatMessage> = synchronized(lock) {
        val pending = inFlightAssistantId
        if (pending == null) _messages.toList() else _messages.filterNot { it.id == pending }
    }

    /**
     * Persistence-safe abandonment: only acts when the model still owns an unsettled turn, so a
     * plain [ConversationCoordinator.persist] between turns does not churn the generation revision
     * (which would invalidate a concurrently prepared admission). Twin of Swift
     * `ChatModel.abandonInFlightTurn` called from `ConversationCoordinator.persist`.
     */
    fun discardUnsettledTurn() {
        val owned = synchronized(lock) { isGenerating || inFlightAssistantId != null }
        if (owned) invalidatePreparedTurns()
    }

    /**
     * Stop the in-flight reply where it is: bump the generation id so no more tokens land, and ask the
     * engine to interrupt its native decode now (the flag-only break lands one token late and does nothing
     * during a non-interruptible prefill — Q-005/Q-217). Also invalidates prepared-but-unstarted
     * turns; only an active send needs native cancellation or settlement.
     * The streamed partial already in the transcript stays AND becomes persistable: an explicit Stop is
     * a decision about the user's time, not an unfinished turn. Twin of iOS `ChatModel.stopGenerating`.
     */
    fun stopGenerating() {
        val revision: Long
        synchronized(lock) {
            revision = ++activeGeneration   // reject queued admissions as well as superseding a running send
            if (!isGenerating) return
            isGenerating = false
            inFlightAssistantId = null      // explicit Stop settles the partial; never discard it
        }
        engine.requestCancel()
        publishPhase(revision, GenerationPhase.IDLE)
    }

    /**
     * Lifecycle invalidation — new chat, open another conversation, delete, clear, Back, or a model
     * switch. Supersedes the running send AND removes the unsettled assistant message, so a reply the
     * user navigated away from is neither shown as an answer nor persisted later. Always bumps the
     * generation id so a prepared-but-unstarted turn cannot begin.
     */
    fun invalidatePreparedTurns() {
        val revision: Long
        val cancel: Boolean
        val snapshot: List<ChatMessage>?
        synchronized(lock) {
            revision = ++activeGeneration
            cancel = isGenerating
            isGenerating = false
            val pending = inFlightAssistantId
            inFlightAssistantId = null
            val index = if (pending == null) -1 else _messages.indexOfFirst { it.id == pending }
            if (index >= 0) _messages.removeAt(index)
            snapshot = if (index >= 0) _messages.toList() else null
        }
        if (cancel) engine.requestCancel()
        publishPhase(revision, GenerationPhase.IDLE)
        snapshot?.let { publish(revision, it) }
    }

    /** Clear the conversation. First stops any in-flight generation so a zombie send can't write into the
     *  now-empty transcript (out of bounds) or resurrect a stale reply. */
    fun reset() {
        val revision: Long
        val cancel: Boolean
        synchronized(lock) { revision = ++activeGeneration; cancel = isGenerating; isGenerating = false; lastHitTokenCap = false; inFlightAssistantId = null; _messages.clear() }
        if (cancel) engine.requestCancel()
        publishPhase(revision, GenerationPhase.IDLE)
        publish(revision, emptyList())
    }

    /** Replace the transcript with a previously persisted conversation (see [ConversationStore]),
     *  so a chat picks up exactly where it left off after a relaunch. First stops any in-flight
     *  generation so tokens from the OUTGOING conversation can't bleed into the one being restored
     *  (the conversation-switch corruption — Q-004/Q-168). */
    fun restore(saved: List<ChatMessage>) {
        val revision: Long
        val cancel: Boolean
        synchronized(lock) {
            revision = ++activeGeneration; cancel = isGenerating; isGenerating = false; lastHitTokenCap = false
            inFlightAssistantId = null
            _messages.clear()
            _messages.addAll(saved)
        }
        if (cancel) engine.requestCancel()
        publishPhase(revision, GenerationPhase.IDLE)
        publish(revision, saved.toList())
    }
}
