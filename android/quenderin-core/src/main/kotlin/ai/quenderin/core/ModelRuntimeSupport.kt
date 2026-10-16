package ai.quenderin.core

/** Only the native capability probe can enable Prism formats; stock and old .so builds fail closed. */
object ModelRuntimeSupport {
    val supportsBonsai: Boolean get() = LlamaEngine.supportsBonsaiRuntime
    val supportsMuse: Boolean get() = LlamaEngine.supportsMuseRuntime
    const val UNAVAILABLE_MESSAGE = "Bonsai and Prism quantizations require an experimental build with the pinned Prism llama.cpp runtime. This build cannot download or load them."
    const val BONSAI_MAX_CONTEXT_TOKENS = 4096
    const val MUSE_MAX_CONTEXT_TOKENS = 4096
    const val MUSE_UNAVAILABLE_MESSAGE = "Muse Spark requires a verified Muse-compatible llama.cpp runtime. This build cannot download or load it."
    const val MUSE_MANIFEST_MESSAGE = "Muse Spark requires the complete verified model from the catalog. Individual shards and custom Muse imports are unavailable."
    private val museIdentity = Regex("muse[\\s_-]*spark", RegexOption.IGNORE_CASE)

    fun isMuse(model: ModelEntry): Boolean =
        (listOf(model.id, model.label, model.filename, model.url) +
            model.artifacts.flatMap { listOf(it.filename, it.url) }).any { museIdentity.containsMatchIn(it) }

    fun unavailableMessage(model: ModelEntry): String = when {
        !isMuse(model) -> UNAVAILABLE_MESSAGE
        !supportsMuse -> MUSE_UNAVAILABLE_MESSAGE
        else -> MUSE_MANIFEST_MESSAGE
    }
    fun requiresMemoryGate(model: ModelEntry): Boolean = requiresPrism(model) || isMuse(model)

    /** Initial Muse support is restricted to the shipped, immutable full model. Identity-only
     * imports cannot grant JNI permission to load a renamed or metadata-only Muse shard. */
    fun isVerifiedMuseManifest(model: ModelEntry): Boolean {
        if (!isMuse(model) || model.artifacts.isEmpty()) return false
        val pinned = ModelCatalog.models.firstOrNull { it.id == model.id && isMuse(it) } ?: return false
        return model.filename == pinned.filename && model.url == pinned.url && model.sha256 == pinned.sha256 &&
            model.downloadBytes == pinned.downloadBytes && model.artifacts == pinned.artifacts &&
            model.quantization == pinned.quantization && model.paramsBillions == pinned.paramsBillions
    }

    fun isBonsai(model: ModelEntry): Boolean =
        listOf(model.id, model.label, model.filename, model.url).any { it.contains("bonsai", ignoreCase = true) }

    fun requiresPrism(model: ModelEntry): Boolean = isBonsai(model) ||
        listOf(model.quantization, model.filename, model.url).any {
            it.contains("PTQ1_0", ignoreCase = true) || it.contains("PQ2_0", ignoreCase = true)
        }

    fun supports(model: ModelEntry): Boolean = (!requiresPrism(model) || supportsBonsai) &&
        (!isMuse(model) || (supportsMuse && isVerifiedMuseManifest(model)))

    /** Conservative capped-context estimate, with overhead added by callers. Unknown imports
     * keep the original 7 GB floor; an id alone cannot claim a smaller artifact's budget. */
    internal fun memoryFootprintGb(model: ModelEntry): Double {
        // This is a 304 GB split model, not its ~13 MB metadata shard or its active-parameter count.
        // Renamed imports cannot use the first shard's size to claim phone-sized memory fitness.
        if (isMuse(model)) return maxOf(330.0, model.ramGB.takeUnless { it.isNaN() } ?: 330.0)
        if (!isBonsai(model)) return model.ramGB
        val pinned = ModelCatalog.models.firstOrNull {
            it.id == model.id && it.filename == model.filename && it.url == model.url &&
                it.sha256 != null && it.sha256 == model.sha256 && it.downloadBytes == model.downloadBytes &&
                it.quantization == model.quantization && it.paramsBillions == model.paramsBillions
        }
        return maxOf(pinned?.ramGB ?: 7.0, model.ramGB)
    }
}
