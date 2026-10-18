package ai.quenderin.core

/** Only the native capability probe can enable Prism formats; stock and old .so builds fail closed. */
object ModelRuntimeSupport {
    val supportsBonsai: Boolean get() = LlamaEngine.supportsBonsaiRuntime
    val supportsMuse: Boolean get() = LlamaEngine.supportsMuseRuntime
    val supportsWeeklyText: Boolean get() = LlamaEngine.supportsWeeklyTextRuntime
    const val WEEKLY_TEXT_UNAVAILABLE_MESSAGE = "Jais 3 and Nemotron 3.5 require a build with the verified architecture backport. Older Prism runtimes cannot download or load them. Support is experimental text chat only."
    private val weeklyTextIdentity = Regex("jais[-_ ]?3|nemotron[-_ ]?(?:3[._-]?5|35)", RegexOption.IGNORE_CASE)
    fun isJais(model: ModelEntry): Boolean = listOf(model.id, model.label, model.filename, model.url).any {
        Regex("jais[-_ ]?3", RegexOption.IGNORE_CASE).containsMatchIn(it)
    }
    fun requiresWeeklyTextRuntime(model: ModelEntry): Boolean =
        listOf(model.id, model.label, model.filename, model.url).any { weeklyTextIdentity.containsMatchIn(it) }
    const val UNAVAILABLE_MESSAGE = "Bonsai, Prism quantizations, MiniCPM-V 4.7 and LFM2.5 24B require a build with the verified Prism llama.cpp runtime. This build cannot download or load them. MiniCPM support is text only."
    const val BONSAI_MAX_CONTEXT_TOKENS = 4096
    const val MUSE_MAX_CONTEXT_TOKENS = 4096
    const val MUSE_UNAVAILABLE_MESSAGE = "Muse Spark requires a verified Muse-compatible llama.cpp runtime. This build cannot download or load it."
    const val MUSE_MANIFEST_MESSAGE = "Muse Spark requires the complete verified model from the catalog. Individual shards and custom Muse imports are unavailable."
    private val museIdentity = Regex("muse[\\s_-]*spark", RegexOption.IGNORE_CASE)

    fun isMuse(model: ModelEntry): Boolean =
        (listOf(model.id, model.label, model.filename, model.url) +
            model.artifacts.flatMap { listOf(it.filename, it.url) }).any { museIdentity.containsMatchIn(it) }

    fun unavailableMessage(model: ModelEntry): String = when {
        requiresWeeklyTextRuntime(model) && !supportsWeeklyText -> WEEKLY_TEXT_UNAVAILABLE_MESSAGE
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

    private val verifiedTextIdentity = Regex("minicpm[-_ ]?v[-_ ]?(?:4[._-]?7|47)|lfm(?:2[._-]?5|25)[-_ ]?24b", RegexOption.IGNORE_CASE)
    fun requiresVerifiedTextRuntime(model: ModelEntry): Boolean =
        listOf(model.id, model.label, model.filename, model.url).any { verifiedTextIdentity.containsMatchIn(it) }

    fun requiresPrism(model: ModelEntry): Boolean = isBonsai(model) || requiresVerifiedTextRuntime(model) || requiresWeeklyTextRuntime(model) ||
        listOf(model.quantization, model.filename, model.url).any {
            it.contains("PTQ1_0", ignoreCase = true) || it.contains("PQ2_0", ignoreCase = true)
        }

    fun supports(model: ModelEntry): Boolean = (!requiresWeeklyTextRuntime(model) || supportsWeeklyText) &&
        (!requiresPrism(model) || supportsBonsai) &&
        (!isMuse(model) || (supportsMuse && isVerifiedMuseManifest(model)))

    /** Conservative capped-context estimate, with overhead added by callers. Unknown imports
     * keep the original 7 GB floor; an id alone cannot claim a smaller artifact's budget. */
    internal fun memoryFootprintGb(model: ModelEntry): Double {
        // This is a 304 GB split model, not its ~13 MB metadata shard or its active-parameter count.
        // Renamed imports cannot use the first shard's size to claim phone-sized memory fitness.
        if (isMuse(model)) return maxOf(330.0, model.ramGB.takeUnless { it.isNaN() } ?: 330.0)
        if (!requiresPrism(model)) return model.ramGB
        val pinned = ModelCatalog.models.firstOrNull {
            it.id == model.id && it.filename == model.filename && it.url == model.url &&
                it.sha256 != null && it.sha256 == model.sha256 && it.downloadBytes == model.downloadBytes &&
                it.quantization == model.quantization && it.paramsBillions == model.paramsBillions
        }
        val importedFloor = when {
            requiresWeeklyTextRuntime(model) && listOf(model.id, model.filename).any { it.contains("nemotron", ignoreCase = true) } -> 28.0
            requiresWeeklyTextRuntime(model) -> 30.0
            !requiresVerifiedTextRuntime(model) -> 7.0
            listOf(model.id, model.filename).any { it.contains("24b", ignoreCase = true) } -> 18.0
            else -> 25.0
        }
        return maxOf(pinned?.ramGB ?: importedFloor, model.ramGB.takeIf { it.isFinite() } ?: importedFloor)
    }
}
