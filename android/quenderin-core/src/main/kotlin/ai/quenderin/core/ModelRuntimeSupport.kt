package ai.quenderin.core

/** Only the native capability probe can enable Prism formats; stock and old .so builds fail closed. */
object ModelRuntimeSupport {
    val supportsBonsai: Boolean get() = LlamaEngine.supportsBonsaiRuntime
    const val UNAVAILABLE_MESSAGE = "Bonsai and Prism quantizations require an experimental build with the pinned Prism llama.cpp runtime. This build cannot download or load them."
    const val BONSAI_MAX_CONTEXT_TOKENS = 4096

    fun isBonsai(model: ModelEntry): Boolean =
        listOf(model.id, model.label, model.filename, model.url).any { it.contains("bonsai", ignoreCase = true) }

    fun requiresPrism(model: ModelEntry): Boolean = isBonsai(model) ||
        listOf(model.quantization, model.filename, model.url).any {
            it.contains("PTQ1_0", ignoreCase = true) || it.contains("PQ2_0", ignoreCase = true)
        }

    fun supports(model: ModelEntry): Boolean = !requiresPrism(model) || supportsBonsai

    /** Conservative RAM floor independent of the compressed file size, with overhead added by callers. */
    internal fun memoryFootprintGb(model: ModelEntry): Double =
        if (isBonsai(model)) maxOf(7.0, model.ramGB) else model.ramGB
}
