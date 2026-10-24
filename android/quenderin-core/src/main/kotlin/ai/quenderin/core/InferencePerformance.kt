package ai.quenderin.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/** Numeric evidence only. Instances belong to one completed native generation, never a shared getter. */
data class InferencePerformanceSample(
    val modelID: String, val artifactSHA256: String, val runtimeID: String, val backendID: String,
    val environmentID: String, val contextTokens: Int, val promptTokens: Int, val prefillTokens: Int,
    val decodedTokens: Int, val prefillMs: Double, val decodeMs: Double, val firstTokenMs: Double,
    val maxGapMs: Double, val loadMs: Double, val cacheMode: String, val thermalState: String,
    val recordedAtMs: Long,
) {
    fun valid(nowMs: Long): Boolean = InferencePerformanceIdentity.validModelID(modelID) &&
        listOf(artifactSHA256, runtimeID, environmentID).all(InferencePerformanceIdentity::isSHA256) &&
        backendID in InferencePerformanceIdentity.REGISTERED_BACKENDS &&
        contextTokens in 1..262144 && promptTokens in 1..contextTokens && prefillTokens in 1..promptTokens &&
        decodedTokens in 32..32768 && decodedTokens <= contextTokens &&
        listOf(prefillMs, decodeMs, firstTokenMs, maxGapMs, loadMs).all { it.isFinite() && it >= 0 && it <= 86_400_000 } &&
        prefillMs > 0 && decodeMs > 0 && firstTokenMs >= prefillMs &&
        firstTokenMs <= prefillMs + decodeMs + 1 && maxGapMs <= decodeMs + 1 &&
        cacheMode in setOf("cold", "prefix") && thermalState in setOf("nominal", "fair", "serious", "critical") &&
        recordedAtMs > 0 && recordedAtMs <= nowMs && nowMs - recordedAtMs <= MAX_AGE_MS

    companion object { const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000 }
}

object InferencePerformanceIdentity {
    // Capabilities are admitted independently. A stored label cannot register a new execution backend.
    val REGISTERED_BACKENDS = setOf("llama", "prism", "muse", "beam")
    private val digestPattern = Regex("^[a-f0-9]{64}$")
    private val modelPattern = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
    fun isSHA256(value: String) = digestPattern.matches(value)
    fun validModelID(value: String) = modelPattern.matches(value) && value.toByteArray(Charsets.UTF_8).size <= 256
    fun fingerprint(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }

    /** Call only after the loader verified every byte against these publisher digests. */
    fun artifact(model: ModelEntry): String? {
        if (runCatching { ModelArtifacts.validate(model) }.isFailure) return null
        if (model.artifacts.isEmpty()) return model.sha256?.lowercase()?.takeIf(::isSHA256)
        if (model.artifacts.any { !isSHA256(it.sha256.lowercase()) }) return null
        // Ordered multipart content identity, independent of local paths and mutable filenames.
        return fingerprint(model.artifacts.joinToString("\n") { "${it.sha256.lowercase()}:${it.downloadBytes}" })
    }
}

/** 64 records / 128 KiB / 30 days. Failed replacement leaves the previous file intact. */
class InferencePerformanceStore(private val file: File, private val now: () -> Long = System::currentTimeMillis) {
    @Synchronized fun samples(): List<InferencePerformanceSample> = try {
        if (!file.isFile || file.length() !in 1..MAX_BYTES.toLong()) emptyList() else {
            // Bound the read too: growth after stat must never allocate an unbounded new size.
            val bytes = ByteArray(MAX_BYTES + 1)
            val size = file.inputStream().use { input ->
                var count = 0
                while (count < bytes.size) {
                    val read = input.read(bytes, count, bytes.size - count)
                    if (read < 0) break
                    if (read == 0) continue
                    count += read
                }
                count
            }
            if (size > MAX_BYTES) emptyList() else decode(bytes.copyOf(size), now())
        }
    } catch (_: Exception) { emptyList() }

    @Synchronized fun record(sample: InferencePerformanceSample): Boolean {
        val timestamp = now()
        if (!sample.valid(timestamp)) return false
        val rows = (samples() + sample).distinct().sortedByDescending { it.recordedAtMs }.take(MAX_RECORDS)
        val bytes = encode(rows)
        if (bytes.size > MAX_BYTES) return false
        var temp: File? = null
        return try {
            val parent = file.absoluteFile.parentFile ?: return false
            if (!parent.isDirectory && !parent.mkdirs()) return false
            temp = File.createTempFile("inference-performance-", ".tmp", parent)
            FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
            // Same-directory POSIX rename replaces atomically on Android/JVM; never remove the old file first.
            temp.renameTo(file)
        } catch (_: Exception) { false } finally { temp?.delete() }
    }

    companion object {
        const val MAX_RECORDS = 64
        const val MAX_BYTES = 131072
        internal fun encode(rows: List<InferencePerformanceSample>): ByteArray {
            val bytes = ByteArrayOutputStream()
            DataOutputStream(bytes).use { out ->
                out.writeInt(0x51504631); out.writeInt(rows.size)
                rows.forEach { s ->
                    listOf(s.modelID, s.artifactSHA256, s.runtimeID, s.backendID, s.environmentID).forEach(out::writeUTF)
                    out.writeInt(s.contextTokens); out.writeInt(s.promptTokens); out.writeInt(s.prefillTokens); out.writeInt(s.decodedTokens)
                    listOf(s.prefillMs, s.decodeMs, s.firstTokenMs, s.maxGapMs, s.loadMs).forEach(out::writeDouble)
                    out.writeUTF(s.cacheMode); out.writeUTF(s.thermalState); out.writeLong(s.recordedAtMs)
                }
            }
            return bytes.toByteArray()
        }
        internal fun decode(bytes: ByteArray, nowMs: Long): List<InferencePerformanceSample> {
            require(bytes.size <= MAX_BYTES)
            return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                require(input.readInt() == 0x51504631)
                val count = input.readInt(); require(count in 0..MAX_RECORDS)
                fun identity(): String = input.readUTF().also { require(it.toByteArray(Charsets.UTF_8).size <= 256) }
                val rows = List(count) {
                    InferencePerformanceSample(identity(), identity(), identity(), identity(), identity(),
                        input.readInt(), input.readInt(), input.readInt(), input.readInt(),
                        input.readDouble(), input.readDouble(), input.readDouble(), input.readDouble(), input.readDouble(),
                        identity(), identity(), input.readLong())
                }
                require(input.available() == 0)
                rows.filter { it.valid(nowMs) }
            }
        }
    }
}

data class AutomaticModelCandidate(
    val modelID: String, val artifactSHA256: String, val runtimeID: String, val backendID: String,
    val environmentID: String, val installed: Boolean, val verified: Boolean, val runtimeAvailable: Boolean,
    val fitsMemory: Boolean, val fitsContext: Boolean, val fitsDisk: Boolean, val supportsTask: Boolean,
    val qualityEligible: Boolean,
    /** Additional admission-time cost; fixture defaults preserve the shared scalar contract. */
    val switchCostFloorMs: Double = 0.0,
    val cacheMode: String? = null,
    val contextTokens: Int? = null,
) {
    val admitted: Boolean get() = installed && verified && runtimeAvailable && fitsMemory && fitsContext &&
        fitsDisk && supportsTask && qualityEligible && InferencePerformanceIdentity.validModelID(modelID) &&
        listOf(artifactSHA256, runtimeID, environmentID).all(InferencePerformanceIdentity::isSHA256) &&
        backendID in InferencePerformanceIdentity.REGISTERED_BACKENDS && switchCostFloorMs.isFinite() && switchCostFloorMs >= 0 &&
        (cacheMode == null || cacheMode in setOf("cold", "prefix")) && (contextTokens == null || contextTokens in 1..262144)
}

data class AutomaticSelectionDecision(val modelID: String, val observed: Boolean, val predictedMs: Double?, val environmentID: String? = null)

object MeasuredAutomaticPolicy {
    fun promptBucket(tokens: Int): Int = when {
        tokens <= 128 -> 128; tokens <= 512 -> 512; tokens <= 2048 -> 2048; tokens <= 8192 -> 8192
        tokens <= 32768 -> 32768; tokens <= 131072 -> 131072; else -> 262144
    }
    fun choose(currentID: String?, candidates: List<AutomaticModelCandidate>, samples: List<InferencePerformanceSample>,
               promptTokens: Int, expectedOutputTokens: Int, contextTokens: Int, cacheMode: String,
               nowMs: Long, fallbackID: String? = null): AutomaticSelectionDecision? {
        if (promptTokens !in 1..contextTokens || expectedOutputTokens !in 1..32768 || contextTokens !in 1..262144) return null
        val admitted = candidates.filter { it.admitted }.sortedBy { it.modelID }
        val current = admitted.firstOrNull { it.modelID == currentID }
        fun estimate(candidate: AutomaticModelCandidate, switching: Boolean): Double? {
            val matches = samples.distinct().filter { s ->
                s.valid(nowMs) && s.modelID == candidate.modelID && s.artifactSHA256 == candidate.artifactSHA256 &&
                    s.runtimeID == candidate.runtimeID && s.backendID == candidate.backendID && s.environmentID == candidate.environmentID &&
                    s.contextTokens == (candidate.contextTokens ?: contextTokens) && s.cacheMode == (candidate.cacheMode ?: cacheMode) && s.thermalState == "nominal" &&
                    promptBucket(s.promptTokens) == promptBucket(promptTokens)
            }
            if (matches.size < 3) return null
            val latency = median(matches.map { it.prefillMs / it.promptTokens * promptTokens + it.decodeMs / it.decodedTokens * expectedOutputTokens })
            return latency + if (switching) maxOf(median(matches.map { it.loadMs }), candidate.switchCostFloorMs) else 0.0
        }
        // Missing evidence is not a reason to displace a viable working model.
        val currentCost = current?.let { estimate(it, false) }
        if (current != null && currentCost == null) return AutomaticSelectionDecision(current.modelID, false, null, current.environmentID)
        val measured = admitted.mapNotNull { c -> estimate(c, c.modelID != currentID)?.let { c to it } }
            .sortedWith(compareBy<Pair<AutomaticModelCandidate, Double>> { it.second }.thenBy { it.first.modelID })
        val best = measured.firstOrNull()
        if (current != null) {
            if (best != null && best.first.modelID != current.modelID && best.second <= currentCost!! * 0.8) {
                return AutomaticSelectionDecision(best.first.modelID, true, best.second, best.first.environmentID)
            }
            return AutomaticSelectionDecision(current.modelID, true, currentCost, current.environmentID)
        }
        if (best != null) return AutomaticSelectionDecision(best.first.modelID, true, best.second, best.first.environmentID)
        return (admitted.firstOrNull { it.modelID == fallbackID } ?: admitted.firstOrNull())?.let {
            AutomaticSelectionDecision(it.modelID, false, null, it.environmentID)
        }
    }
    private fun median(values: List<Double>): Double {
        val sorted = values.sorted(); val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) (sorted[middle - 1] + sorted[middle]) / 2 else sorted[middle]
    }
}

/** Manual actions invalidate an awaiting automatic decision before the loader may commit it. */
class AutomaticSelectionMode(private val read: () -> Boolean = { false }, private val write: (Boolean) -> Unit = {}) {
    @Volatile private var revision = 0L
    @Synchronized fun enabled(): Boolean = read()
    @Synchronized fun setEnabled(value: Boolean) { revision++; write(value) }
    @Synchronized fun manualChoice() { revision++; write(false) }
    @Synchronized fun ticket(): Long? = if (read()) revision else null
    @Synchronized fun current(ticket: Long): Boolean = read() && revision == ticket
    @Synchronized fun revisionToken(): Long = revision
    @Synchronized fun currentRevision(token: Long): Boolean = revision == token
    companion object {
        const val PREFERENCE_KEY = "quenderin.automaticModelSelection"
        const val MANUAL_MODEL_KEY = "quenderin.manualModelID"
    }
}

/** Runtime capability comes from the concrete loaded library, independently of history. */
data class AutomaticExecutionProfile(val runtimeID: String, val backendID: String, val environmentID: String,
                                     val contextTokens: Int, val thermalState: ThermalLevel,
                                     val cacheMode: String = "cold", val promptTokens: Int? = null)

/** One candidate activation and one loader-owned recovery at most. No installers or network ports. */
class AutomaticTurnSelection(private val mode: AutomaticSelectionMode, private val now: () -> Long = System::currentTimeMillis) {
    private val failures = LinkedHashMap<String, Long>()
    @Synchronized fun prepare(
        firstTurn: Boolean, currentID: String?, candidates: List<AutomaticModelCandidate>,
        samples: List<InferencePerformanceSample>, promptTokens: Int, expectedOutputTokens: Int,
        contextTokens: Int, cacheMode: String = "cold", fallbackID: String? = null,
        isCurrent: () -> Boolean = { true },
        activate: (String, () -> Boolean) -> Boolean,
    ): AutomaticSelectionDecision? {
        val ticket = mode.ticket() ?: return null
        if (!firstTurn) return null
        val timestamp = now()
        failures.entries.removeAll { timestamp - it.value >= 600_000 || timestamp < it.value }
        val available = candidates.filter { it.modelID == currentID || it.modelID !in failures }
        val decision = MeasuredAutomaticPolicy.choose(currentID, available, samples, promptTokens,
            expectedOutputTokens, contextTokens, cacheMode, timestamp, fallbackID) ?: return null
        if (!mode.current(ticket) || !isCurrent()) return null
        if (decision.modelID == currentID) return decision
        if (!activate(decision.modelID) { mode.current(ticket) && isCurrent() }) {
            failures[decision.modelID] = timestamp
            while (failures.size > 64) failures.remove(failures.keys.first())
            return null
        }
        return decision.takeIf { mode.current(ticket) && isCurrent() }
    }
}

class AutomaticSelectionChangedException : IllegalStateException("Model choice changed. Your draft is ready to send with the selected model.")
data class PreparedLocalTurn(val model: ModelEntry, val accepts: () -> Boolean)
data class ManualModelIntent(val model: ModelEntry, val revision: Long)
data class LocalTurnIntent(val revision: Long, val requiredManualModelID: String?, val ready: Boolean)
data class AutomaticChatRequest(val text: String, val documents: List<AttachedDocument> = emptyList(),
                                val history: List<ChatMessage> = emptyList()) {
    fun windowedHistory(model: ModelEntry, contextTokens: Int): List<ChatMessage> {
        val all = history + ChatMessage(Role.USER, text.trim(), documents)
        return ConversationContext(systemPrompt = ChatTier.of(model).systemPrompt).windowedHistory(
            all.map { if (it.documents.isEmpty()) it else it.copy(text = it.engineText, documents = emptyList()) }, contextTokens)
    }
}
