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

    /** Best-effort: interrupt an in-flight [complete] (e.g. a model switch or stop button). Must NOT
     *  take the engine's generation lock — it has to signal a generation that already holds it.
     *  Default no-op for engines without interruption (mock, scripted, tests). Audit M3. */
    fun requestCancel() {}
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
