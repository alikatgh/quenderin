package ai.quenderin.core

import java.io.RandomAccessFile

/** Only the native capability probe can enable Prism formats; stock and old .so builds fail closed. */
object ModelRuntimeSupport {
    private fun identities(model: ModelEntry) = listOf(model.id, model.label, model.filename, model.url) +
        model.artifacts.flatMap { listOf(it.filename, it.url) }
    private fun key(value: String) = value.lowercase().replace(Regex("[^a-z0-9]"), "")
    private fun decodedIdentity(value: String): String = if (value.length > 16_384) "" else
        runCatching { java.net.URLDecoder.decode(value, "UTF-8") }.getOrDefault(value)
    internal fun unsupportedWorkflowReason(identifiers: List<String>, architecture: String = "", allowPinnedBeam: Boolean = false): String? {
        if (architecture.length > 256 || identifiers.any { it.length > 16_384 }) return "The model identity is too long to validate safely."
        val values = identifiers.map(::decodedIdentity)
        val keys = values.map(::key)
        val arch = key(architecture)
        return when {
            !allowPinnedBeam && (arch == "beam" || values.any { Regex("(?:^|[^a-z0-9])beam(?:[0-9]|[^a-z0-9]|$)", RegexOption.IGNORE_CASE).containsMatchIn(it) }) ->
                "Beam requires the complete multipart installer and Harmony chat adapter. Generic chat is unavailable."
            keys.any { it.contains("hymemory") } -> "Hy-Memory requires a specialized memory-proposal workflow with JSON validation and explicit save approval. Generic chat is unavailable."
            keys.any { it.contains("supervl") && (it.contains("nemotron") || it.contains("120b")) } -> "Use Ask about an image with the complete Nemotron Super VL model and matching projector."
            arch == "step5" || arch == "step5vl" || keys.any { it.contains("step5") && !it.contains("step35") } -> "Use the Step 5 workflow with the pinned official CUDA gateway on your own host."
            arch.contains("graniteswitch") || keys.any { it.contains("granite") && it.contains("switch") && it.contains("41") } -> "Use Granite Switch 4.1 chat with a verified converted model and its provenance record."
            keys.any { it.contains("bolte4b") || (it.contains("nemotron") && it.contains("e4b")) } -> "Nemotron Bolt E4B has no verified public artifact in this release."
            keys.any { it.contains("nemotron35") } && !keys.any { Regex("nemotron35.*bolt.*74b.*a9b").containsMatchIn(it) } -> "This Nemotron 3.5 variant has not been validated. Only Bolt 74B-A9B is available as experimental text chat."
            else -> null
        }
    }
    fun unsupportedWorkflowReason(model: ModelEntry): String? = unsupportedWorkflowReason(identities(model), allowPinnedBeam = isVerifiedBeamManifest(model))

    /** Bounded metadata-only preflight. Never reads tensor payloads or allocates model weights. */
    private data class MetadataIdentity(val architecture: String, val name: String, val splits: Long, val blockCount: Long?, val embeddingLength: Long?)
    private fun metadataIdentity(path: String): MetadataIdentity = RandomAccessFile(path, "r").use { file ->
        val limit = minOf(file.length(), 64L * 1024 * 1024)
        fun ensure(count: Long) { require(count >= 0 && count <= limit - file.filePointer) { "Truncated or oversized GGUF metadata" } }
        fun integer(width: Int): Long {
            ensure(width.toLong())
            val bytes = ByteArray(width)
            file.readFully(bytes)
            var value = 0L
            repeat(width) { value = value or ((bytes[it].toLong() and 255) shl (it * 8)) }
            require(value >= 0) { "Oversized GGUF metadata value" }
            return value
        }
        fun string(maximum: Long): String {
            val size = integer(8)
            require(size <= maximum) { "Oversized GGUF identity string" }
            ensure(size)
            val bytes = ByteArray(size.toInt())
            file.readFully(bytes)
            return Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        }
        fun skip(count: Long) { ensure(count); file.seek(file.filePointer + count) }
        fun width(type: Long): Long = when (type) { 0L, 1L, 7L -> 1; 2L, 3L -> 2; 4L, 5L, 6L -> 4; 10L, 11L, 12L -> 8; else -> error("Unknown GGUF metadata type") }
        require(integer(4) == 0x46554747L) { "Invalid GGUF metadata" }
        require(integer(4) in 2L..3L) { "Unsupported GGUF version" }
        integer(8) // tensor count, never read
        val count = integer(8)
        require(count <= 100_000) { "Too many GGUF metadata keys" }
        var architecture: String? = null
        var name: String? = null
        var splits = 1L
        var blockCount: Long? = null
        var embeddingLength: Long? = null
        repeat(count.toInt()) {
            val field = string(1024)
            val type = integer(4)
            if (field == "general.architecture" || field == "general.name") {
                require(type == 8L) { "GGUF identity must be a string" }
                val value = string(if (field == "general.architecture") 256 else 4096)
                if (field == "general.architecture") {
                    require(architecture == null) { "Duplicate GGUF architecture" }; architecture = value
                } else { require(name == null) { "Duplicate GGUF name" }; name = value }
            } else if (field == "split.count") {
                require(type in listOf(0L, 2L, 4L, 10L)) { "Invalid GGUF split count" }
                splits = integer(width(type).toInt())
                require(splits in 1L..64L) { "Invalid GGUF split count" }
            } else if (field == "graniteswitch.block_count" || field == "graniteswitch.embedding_length") {
                require(type in listOf(0L, 2L, 4L, 10L)) { "Invalid Granite dimensions" }
                val value = integer(width(type).toInt())
                if (field.endsWith("block_count")) { require(blockCount == null && value <= 1024); blockCount = value }
                else { require(embeddingLength == null && value <= 65536); embeddingLength = value }
            } else when (type) {
                8L -> skip(integer(8))
                9L -> {
                    val element = integer(4)
                    val size = integer(8)
                    require(size <= 2_000_000 && element != 9L) { "Oversized or nested GGUF array" }
                    if (element == 8L) repeat(size.toInt()) { skip(integer(8)) } else skip(size * width(element))
                }
                else -> skip(width(type))
            }
        }
        require(!architecture.isNullOrEmpty()) { "GGUF architecture is missing" }
        MetadataIdentity(architecture.orEmpty(), name.orEmpty(), splits, blockCount, embeddingLength)
    }
    internal fun graniteMetadataMatches(path: String): Boolean = runCatching {
        val metadata = metadataIdentity(path)
        metadata.architecture == "graniteswitch" && metadata.splits == 1L && metadata.blockCount == 40L && metadata.embeddingLength == 4096L
    }.getOrDefault(false)
    internal fun metadataUnavailableReason(path: String, model: ModelEntry? = null): String? {
        val (architecture, name, splits) = metadataIdentity(path)
        return unsupportedWorkflowReason(listOf(name), architecture, model != null && isVerifiedBeamManifest(model))
            ?: (if ((architecture == "beam" || (model != null && isBeam(model))) &&
                (architecture != "beam" || splits != 4L || model == null || !isVerifiedBeamManifest(model) || !supportsBeam)) BEAM_UNAVAILABLE_MESSAGE else null)
            ?: (if ((architecture == "k2-horizon" || isWeeklyIdentity(name)) && !supportsWeeklyText) WEEKLY_TEXT_UNAVAILABLE_MESSAGE else null)
    }
    /** Read-only specialist identity check; it does not lift ordinary chat guards. */
    fun hyMemoryMetadataMatches(path: String): Boolean = runCatching {
        val (architecture, _, splits) = metadataIdentity(path)
        architecture == "hy_v3" && splits == 1L
    }.getOrDefault(false)
    val supportsBonsai: Boolean get() = LlamaEngine.supportsBonsaiRuntime
    val supportsMuse: Boolean get() = LlamaEngine.supportsMuseRuntime
    val supportsBeam: Boolean get() = LlamaEngine.supportsBeamRuntime
    const val BEAM_UNAVAILABLE_MESSAGE = "Beam requires the verified Beam runtime, all four pinned shards and at least 160 GiB plus context headroom. Experimental text chat only."
    fun isBeam(model: ModelEntry): Boolean = identities(model).any { Regex("(?:^|[^a-z0-9])beam(?:[0-9]|[^a-z0-9]|$)", RegexOption.IGNORE_CASE).containsMatchIn(decodedIdentity(it)) }
    fun isVerifiedBeamManifest(model: ModelEntry): Boolean {
        val pinned = ModelCatalog.models.firstOrNull { it.id == "beam-1.0-501b-a23b-ud-iq2-xxs" } ?: return false
        return model == pinned && model.artifacts == BeamModelArtifacts.parts && model.downloadBytes == 133885310500L
    }
    val supportsWeeklyText: Boolean get() = LlamaEngine.supportsWeeklyTextRuntime
    const val WEEKLY_TEXT_UNAVAILABLE_MESSAGE = "Jais 3 and Nemotron 3.5 require a build with the verified architecture backport. Older Prism runtimes cannot download or load them. Support is experimental text chat only."
    private fun isWeeklyIdentity(value: String): Boolean = key(decodedIdentity(value)).let { it.contains("jais3") || Regex("nemotron35.*bolt.*74b.*a9b").containsMatchIn(it) }
    fun isJais(model: ModelEntry): Boolean = listOf(model.id, model.label, model.filename, model.url).any {
        Regex("jais[-_ ]?3", RegexOption.IGNORE_CASE).containsMatchIn(it)
    }
    fun requiresWeeklyTextRuntime(model: ModelEntry): Boolean =
        identities(model).any(::isWeeklyIdentity)
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
        unsupportedWorkflowReason(model) != null -> unsupportedWorkflowReason(model)!!
        isBeam(model) && (!supportsBeam || !isVerifiedBeamManifest(model)) -> BEAM_UNAVAILABLE_MESSAGE
        requiresWeeklyTextRuntime(model) && !supportsWeeklyText -> WEEKLY_TEXT_UNAVAILABLE_MESSAGE
        !isMuse(model) -> UNAVAILABLE_MESSAGE
        !supportsMuse -> MUSE_UNAVAILABLE_MESSAGE
        else -> MUSE_MANIFEST_MESSAGE
    }
    fun requiresMemoryGate(model: ModelEntry): Boolean = requiresPrism(model) || isMuse(model) || isBeam(model)

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

    fun requiresPrism(model: ModelEntry): Boolean = isBeam(model) || isBonsai(model) || requiresVerifiedTextRuntime(model) || requiresWeeklyTextRuntime(model) ||
        listOf(model.quantization, model.filename, model.url).any {
            it.contains("PTQ1_0", ignoreCase = true) || it.contains("PQ2_0", ignoreCase = true)
        }

    fun supports(model: ModelEntry): Boolean = unsupportedWorkflowReason(model) == null &&
        (!isBeam(model) || (supportsBeam && isVerifiedBeamManifest(model))) &&
        (!requiresWeeklyTextRuntime(model) || supportsWeeklyText) &&
        (!requiresPrism(model) || supportsBonsai) &&
        (!isMuse(model) || (supportsMuse && isVerifiedMuseManifest(model)))

    /** Conservative capped-context estimate, with overhead added by callers. Unknown imports
     * keep the original 7 GB floor; an id alone cannot claim a smaller artifact's budget. */
    internal fun memoryFootprintGb(model: ModelEntry): Double {
        // This is a 304 GB split model, not its ~13 MB metadata shard or its active-parameter count.
        // Renamed imports cannot use the first shard's size to claim phone-sized memory fitness.
        if (isBeam(model)) return maxOf(160.0, model.ramGB.takeIf { it.isFinite() } ?: 160.0)
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
