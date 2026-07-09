package ai.quenderin.core

/**
 * Runtime-agnostic on-device inference seam — the Android twin of the Swift
 * `InferenceEngine`. The real implementation (`LlamaEngine`) bridges to llama.cpp
 * through JNI over the NDK; this interface + the mock let the app and tests depend
 * on the seam, not the engine.
 *
 * (Kept synchronous here so the pure-Kotlin core compiles + tests on the JVM. The
 * Android module wraps `complete` in a coroutine and exposes token Flow.)
 */
interface InferenceEngine {
    val loadedModelId: String?

    /**
     * The ACTUAL context window (`n_ctx`, tokens) of the currently loaded model, or null when unknown
     * (nothing loaded, or an engine that doesn't model a native window — mock/scripted). A real engine
     * ([LlamaEngine]) sizes this from the device's memory at load, often 512–2048 on phones — so the chat
     * history must be trimmed to THIS, not a hardcoded 4096 that silently overflows the native window
     * (Q-167). Default null keeps the mock/scripted engines and their tests unchanged.
     */
    val loadedContextTokens: Int? get() = null

    fun load(model: ModelEntry, filePath: String)
    fun unload()
    /** The full completion for a prompt. */
    fun complete(prompt: String): String

    /**
     * Streaming completion: [onToken] is invoked with each decoded piece as it's produced, and the
     * full text is also returned. This is what lets a reply appear LIVE in the chat instead of the UI
     * sitting blank for the whole (multi-second) generation — the difference between "it's typing" and
     * "it's not answering". Default: fall back to the blocking [complete] (mock/scripted don't stream);
     * `LlamaEngine` overrides it with the real per-token JNI callback.
     */
    fun complete(prompt: String, onToken: (String) -> Unit): String = complete(prompt)

    /**
     * Grammar-constrained completion — the agent DECISION decode. Masks every token that can't continue
     * [grammar] (a GBNF string), so an agent decision CANNOT be prose. Parity with the iOS engine, which
     * applies the SAME grammar via `llama_sampler_init_grammar`; until now Android decoded the decision
     * unconstrained (AgentDecisionGrammar's constant was "the contract until the JNI grows a grammar
     * parameter" — this IS that parameter). Default IGNORES the grammar and falls back to plain [complete]
     * so mock/scripted engines (and the JVM tests) are unchanged; only [LlamaEngine] applies it natively.
     * Sampling defaults match `shared/sampling-profiles.json` → `agent_decision` (CI: check:sampling-parity).
     */
    fun completeWithGrammar(
        prompt: String, grammar: String, maxTokens: Int = 192,
        topP: Float = 0.8f, topK: Int = 20, temperature: Float = 0.7f,
        repeatPenalty: Float = 1.1f, repeatLastN: Int = 256,
    ): String = complete(prompt)

    /**
     * A short, UNCONSTRAINED reasoning decode — the "think, then decide" pass (twin of the iOS
     * deliberation decode). No grammar (the model must be free to reason), hard-capped so the reasoning
     * can't run away and starve the decision that follows. Default falls back to plain [complete] so
     * mock/scripted engines are unchanged; [LlamaEngine] caps it at [maxTokens]. Only meaningful once the
     * decision decode is grammar-forced (which is why it lands AFTER grammar-in-JNI): otherwise the model
     * could already reason inline.
     * Default maxTokens matches `shared/sampling-profiles.json` → `agent_deliberation`.
     */
    fun completeThinking(prompt: String, maxTokens: Int = 256): String = complete(prompt)

    /**
     * Streaming chat completion from the STRUCTURED conversation (system prompt + turns). A real engine
     * ([LlamaEngine]) formats this with the model's OWN chat template so the model answers as an assistant
     * and stops at its end-of-turn token — the difference between a snappy short reply and one that grinds
     * out `maxTokens` of rambling every time. Default: flatten to the plain "User:/Assistant:" prompt and
     * stream that, so the mock/scripted engines (and tests) are unchanged.
     */
    fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
        val flat = buildString {
            if (systemPrompt.isNotEmpty()) { append(systemPrompt); append("\n\n") }
            history.forEach {
                append(if (it.role == Role.USER) "User: " else "Assistant: ").append(it.text).append("\n")
            }
            append("Assistant:")
        }
        return complete(flat, onToken)
    }

    /** Best-effort: interrupt an in-flight [complete] (e.g. a model switch or stop button). Must NOT
     *  take the engine's generation lock — it has to signal a generation that already holds it.
     *  Default no-op for engines without interruption (mock, scripted, tests). Audit M3. */
    fun requestCancel() {}

    /**
     * True when the most recent generation stopped at the token budget (not EOG / cancel).
     * Default false — mocks and pure-compute tools never hit a real cap. LlamaEngine overrides
     * via the native hitTokenCap flag so ChatModel can show "Continue".
     */
    fun lastHitTokenCap(): Boolean = false
}

class EngineNotLoadedException : IllegalStateException("No model is loaded")

/** Canned engine for previews, tests, and bringing up the app before JNI exists. */
class MockInferenceEngine(
    private val cannedReply: String = "Hello from Quenderin — running on-device, offline.",
) : InferenceEngine {
    override var loadedModelId: String? = null
        private set

    override fun load(model: ModelEntry, filePath: String) { loadedModelId = model.id }
    override fun unload() { loadedModelId = null }

    override fun complete(prompt: String): String {
        if (loadedModelId == null) throw EngineNotLoadedException()
        return cannedReply
    }
}
