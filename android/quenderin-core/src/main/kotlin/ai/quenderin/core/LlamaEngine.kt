package ai.quenderin.core

/**
 * Real on-device engine: a thin Kotlin adapter over llama.cpp, reached through JNI
 * over the NDK. The C++ side (`jni/llama_jni.cpp`) is compiled by the app module's
 * `externalNativeBuild` (CMake) into `libquenderin_llama.so` for each ABI — see
 * `android/INTEGRATION.md`. Twin of Swift `LlamaEngine` (gated behind
 * `#if canImport(llama)`); llama.cpp stays C/C++, this is only the adapter.
 *
 * Crucially, this Kotlin compiles and unit-tests on a plain JVM: `System.loadLibrary`
 * is guarded, so off-device (no `.so`) [available] is `false` and every call fails
 * cleanly with [UNAVAILABLE_MSG] instead of crashing. On a real device build with the
 * `.so` present, [available] flips `true` and calls bridge into llama.cpp. This is the
 * "fails cleanly until linked" contract the tests pin down.
 */
class LlamaEngine(
    private val contextTokens: Int = 4096,
    /** Worker threads; 0 → the native side picks (≈ performance cores). */
    private val threads: Int = 0,
    private val maxTokens: Int = 512,
) : InferenceEngine {

    override var loadedModelId: String? = null
        private set

    /** Opaque native pointer (a `llama_context*` on the C++ side); 0 = nothing loaded. */
    private var handle: Long = 0L

    /** True only when the native library actually loaded — i.e. a real device build. */
    fun available(): Boolean = NATIVE_AVAILABLE

    override fun load(model: ModelEntry, filePath: String) {
        check(NATIVE_AVAILABLE) { UNAVAILABLE_MSG }
        if (handle != 0L) unload()
        handle = nativeLoad(filePath, contextTokens, threads)
        if (handle == 0L) throw IllegalStateException("llama.cpp could not load ${model.filename}")
        loadedModelId = model.id
    }

    override fun unload() {
        if (handle != 0L) {
            nativeFree(handle)
            handle = 0L
        }
        loadedModelId = null
    }

    override fun complete(prompt: String): String {
        ensureReady()
        return nativeComplete(handle, prompt, maxTokens)
    }

    /**
     * Streaming completion: the native side invokes [onToken] per decoded piece and
     * also returns the full text. Lets the Compose layer render tokens as they arrive.
     */
    fun complete(prompt: String, onToken: (String) -> Unit): String {
        ensureReady()
        return nativeCompleteStreaming(handle, prompt, maxTokens, TokenSink { onToken(it) })
    }

    private fun ensureReady() {
        if (!NATIVE_AVAILABLE) throw IllegalStateException(UNAVAILABLE_MSG)
        if (handle == 0L || loadedModelId == null) throw EngineNotLoadedException()
    }

    // --- JNI bridge — implemented in jni/llama_jni.cpp, resolved only when called ---
    private external fun nativeLoad(modelPath: String, contextTokens: Int, threads: Int): Long
    private external fun nativeComplete(handle: Long, prompt: String, maxTokens: Int): String
    private external fun nativeCompleteStreaming(handle: Long, prompt: String, maxTokens: Int, sink: TokenSink): String
    private external fun nativeFree(handle: Long)

    /** JNI-friendly callback (a single known method signature `(Ljava/lang/String;)V`). */
    fun interface TokenSink {
        fun onToken(piece: String)
    }

    companion object {
        const val UNAVAILABLE_MSG: String =
            "Native llama.cpp is not linked: build jni/ for this ABI (see android/INTEGRATION.md). " +
                "Use MockInferenceEngine until then."

        /**
         * Attempts to load `libquenderin_llama.so` once. On the JVM / off-device this
         * throws [UnsatisfiedLinkError], which we swallow so the class stays usable and
         * the seam degrades to a clear error rather than a crash.
         */
        val NATIVE_AVAILABLE: Boolean = try {
            System.loadLibrary("quenderin_llama")
            true
        } catch (t: Throwable) {
            false
        }
    }
}
