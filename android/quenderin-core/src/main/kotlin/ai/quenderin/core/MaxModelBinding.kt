package ai.quenderin.core

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Pure-Kotlin handle over the portable MAX model boundary. This is deliberately
 * not wired into model selection or chat: no production runner exists, so
 * [MaxModelBinding.available] is false and opening fails closed.
 *
 * The native library is the canonical C adapter (`native/max-runtime`) plus a
 * thin JNI registry (`android/jni/max_jni.cpp`). JNI callbacks run on the
 * generation thread; cancellation is an atomic native lease, so it can arrive
 * from a sink, another thread or the UI without taking the generation lock.
 */
object MaxModelLimits {
    const val MAX_FILES = 8
    const val MAX_CONTEXT = 4096
    const val MAX_OUTPUT = 1024
    const val MAX_PROMPT_BYTES = 8192
    const val MAX_FILE_BYTES = 8L * 1024 * 1024 * 1024
    const val MAX_TOTAL_BYTES = 12L * 1024 * 1024 * 1024
    const val MAX_PATH_BYTES = 4096
}

object MaxModelCode {
    const val OK = 0
    const val INVALID_ARGUMENT = 1
    const val UNAVAILABLE = 2
    const val RUNTIME_ERROR = 3
    const val CANCELLED = 4
    const val CONTRACT_MISMATCH = 5
    const val BUSY = 6
}

object MaxModelStatus {
    const val COMPLETE = 0
    const val CANCELLED = 1
    const val RUNNER_ERROR = 2
    const val OUTPUT_CAP = 3
    const val SINK_STOPPED = 4
    const val CLAMPED = 5
    const val REJECTED = 6
}

data class MaxModelFile(val path: String, val bytes: Long, val sha256: String)

data class MaxModelReceipt(
    val files: List<MaxModelFile>,
    val runnerName: String,
    val backend: String,
    val contextTokens: Int,
    val maxOutputTokens: Int,
) {
    init {
        require(files.size in 1..MaxModelLimits.MAX_FILES) { "One to ${MaxModelLimits.MAX_FILES} artifact files are required." }
        require(runnerName.encodeToByteArray().size in 1..63) { "Runner identity is outside the reviewed range." }
        require(backend.encodeToByteArray().size in 1..15) { "Compiled backend identity is outside the reviewed range." }
        require(contextTokens in 1..MaxModelLimits.MAX_CONTEXT) { "Context budget is outside the reviewed range." }
        require(maxOutputTokens in 1..MaxModelLimits.MAX_OUTPUT && maxOutputTokens <= contextTokens) {
            "Output budget is outside the reviewed range."
        }
        var total = 0L
        files.forEach { file ->
            require(File(file.path).isAbsolute && !file.path.contains('\u0000') &&
                file.path.encodeToByteArray().size <= MaxModelLimits.MAX_PATH_BYTES) {
                "Artifact paths must be absolute app-private paths."
            }
            require(file.bytes in 1..MaxModelLimits.MAX_FILE_BYTES) { "Artifact size is outside the reviewed range." }
            require(file.sha256.matches(Regex("[a-f0-9]{64}"))) { "Artifact SHA-256 must be 64 lowercase hex characters." }
            require(total <= MaxModelLimits.MAX_TOTAL_BYTES - file.bytes) { "Artifact set exceeds the total byte budget." }
            total += file.bytes
        }
    }
}

data class MaxModelCapability(
    val code: Int,
    val contractOk: Boolean,
    val loadProbePassed: Boolean,
    val available: Boolean,
    val runner: String,
    val backend: String,
    val reason: String,
    val contextTokens: Int,
    val maxOutputTokens: Int,
)

data class MaxVerification(val code: Int, val message: String) {
    val succeeded: Boolean get() = code == MaxModelCode.OK
}

data class MaxGenerationPerformance(
    val promptTokens: Int,
    val decodedTokens: Int,
    val prefillMs: Double,
    val decodeMs: Double,
    val firstTokenMs: Double,
    val maxGapMs: Double,
    val status: Int,
    val cacheMode: Int,
) {
    companion object {
        /** Native layout: prompt, decoded, prefill, decode, first token, max gap, status, cache. */
        fun from(values: DoubleArray): MaxGenerationPerformance {
            require(values.size >= 8) { "Performance array is too short." }
            fun time(value: Double) = if (value.isFinite()) value.coerceAtLeast(0.0) else 0.0
            fun count(value: Double) = if (value.isFinite()) value.toLong().coerceIn(0, Int.MAX_VALUE.toLong()).toInt() else 0
            return MaxGenerationPerformance(
                promptTokens = count(values[0]),
                decodedTokens = count(values[1]),
                prefillMs = time(values[2]),
                decodeMs = time(values[3]),
                firstTokenMs = time(values[4]),
                maxGapMs = time(values[5]),
                status = count(values[6]),
                cacheMode = count(values[7]),
            )
        }
    }
}

data class MaxGenerationResult(
    val code: Int,
    val performance: MaxGenerationPerformance,
    val message: String?,
) {
    val succeeded: Boolean get() = code == MaxModelCode.OK
}

sealed interface MaxOpenResult {
    data class Opened(val handle: MaxModelHandle) : MaxOpenResult
    data class Unavailable(val code: Int, val message: String) : MaxOpenResult
}

enum class MaxCloseResult { CLOSED, BUSY, INVALID }

fun interface MaxTokenSink {
    /** Return false to stop generation. The callback runs on the generation thread. */
    fun onToken(text: String): Boolean
}

internal interface MaxModelApi {
    fun verify(receipt: MaxModelReceipt): MaxVerification
    fun capability(receipt: MaxModelReceipt, loadProbePassed: Boolean): MaxModelCapability
    fun open(receipt: MaxModelReceipt): MaxOpenResult
    fun generate(
        handle: Long,
        runId: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        seed: Int,
        sink: MaxTokenSink,
    ): MaxGenerationResult
    fun cancel(handle: Long, runId: Long): Boolean
    fun close(handle: Long): Int
}

internal object MaxModelNative {
    val loaded: Boolean by lazy {
        try {
            System.loadLibrary("quenderin_max_jni")
            nativeBridgeAbi() == 1
        } catch (_: UnsatisfiedLinkError) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    @JvmStatic external fun nativeBridgeAbi(): Int
    @JvmStatic external fun nativeVerify(
        paths: Array<String>,
        sizes: LongArray,
        hashes: Array<String>,
        runnerName: String,
        backend: String,
        contextTokens: Int,
        maxOutputTokens: Int,
        error: Array<String>,
    ): Int

    @JvmStatic external fun nativeCapability(
        paths: Array<String>,
        sizes: LongArray,
        hashes: Array<String>,
        runnerName: String,
        backend: String,
        contextTokens: Int,
        maxOutputTokens: Int,
        loadProbePassed: Boolean,
        result: IntArray,
        text: Array<String>,
    ): Int

    @JvmStatic external fun nativeOpen(
        paths: Array<String>,
        sizes: LongArray,
        hashes: Array<String>,
        runnerName: String,
        backend: String,
        contextTokens: Int,
        maxOutputTokens: Int,
        code: IntArray,
        error: Array<String>,
    ): Long

    @JvmStatic external fun nativeGenerate(
        handle: Long,
        runId: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        seed: Int,
        sink: MaxTokenSink,
        performance: DoubleArray,
        error: Array<String>,
    ): Int

    @JvmStatic external fun nativeCancel(handle: Long, runId: Long): Boolean
    @JvmStatic external fun nativeClose(handle: Long): Int
}

private object NativeMaxModelApi : MaxModelApi {
    private fun receiptArrays(receipt: MaxModelReceipt): Triple<Array<String>, LongArray, Array<String>> =
        Triple(receipt.files.map { it.path }.toTypedArray(), receipt.files.map { it.bytes }.toLongArray(),
            receipt.files.map { it.sha256 }.toTypedArray())

    private fun unavailable(message: String) = MaxModelCapability(
        code = MaxModelCode.UNAVAILABLE, contractOk = false, loadProbePassed = false,
        available = false, runner = "", backend = "", reason = message, contextTokens = 0, maxOutputTokens = 0,
    )

    override fun verify(receipt: MaxModelReceipt): MaxVerification {
        if (!MaxModelNative.loaded) {
            return MaxVerification(MaxModelCode.UNAVAILABLE, "This build does not include the MAX JNI library.")
        }
        val (paths, sizes, hashes) = receiptArrays(receipt)
        val error = arrayOf("")
        val code = MaxModelNative.nativeVerify(paths, sizes, hashes, receipt.runnerName, receipt.backend,
            receipt.contextTokens, receipt.maxOutputTokens, error)
        return MaxVerification(code, error[0])
    }

    override fun capability(receipt: MaxModelReceipt, loadProbePassed: Boolean): MaxModelCapability {
        if (!MaxModelNative.loaded) return unavailable("This build does not include the MAX JNI library.")
        val (paths, sizes, hashes) = receiptArrays(receipt)
        val result = IntArray(5)
        val text = arrayOf("", "", "")
        val code = MaxModelNative.nativeCapability(paths, sizes, hashes, receipt.runnerName, receipt.backend,
            receipt.contextTokens, receipt.maxOutputTokens, loadProbePassed, result, text)
        return MaxModelCapability(
            code = code,
            contractOk = result[0] != 0,
            loadProbePassed = result[1] != 0,
            available = result[2] != 0,
            runner = text[0],
            backend = text[1],
            reason = text[2],
            contextTokens = result[3],
            maxOutputTokens = result[4],
        )
    }

    override fun open(receipt: MaxModelReceipt): MaxOpenResult {
        if (!MaxModelNative.loaded) {
            return MaxOpenResult.Unavailable(MaxModelCode.UNAVAILABLE,
                "This build does not include the MAX JNI library.")
        }
        val (paths, sizes, hashes) = receiptArrays(receipt)
        val code = IntArray(1)
        val error = arrayOf("")
        val handle = MaxModelNative.nativeOpen(paths, sizes, hashes, receipt.runnerName, receipt.backend,
            receipt.contextTokens, receipt.maxOutputTokens, code, error)
        return if (handle != 0L && code[0] == MaxModelCode.OK) {
            MaxOpenResult.Opened(MaxModelHandle(handle, receipt, this))
        } else {
            MaxOpenResult.Unavailable(code[0], error[0].ifEmpty { "The MAX model could not be opened." })
        }
    }

    override fun generate(
        handle: Long,
        runId: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        seed: Int,
        sink: MaxTokenSink,
    ): MaxGenerationResult {
        val performance = DoubleArray(8)
        val error = arrayOf("")
        val code = MaxModelNative.nativeGenerate(handle, runId, prompt, maxTokens, temperature, topP, seed,
            sink, performance, error)
        return MaxGenerationResult(code, MaxGenerationPerformance.from(performance), error[0].ifEmpty { null })
    }

    override fun cancel(handle: Long, runId: Long): Boolean = MaxModelNative.nativeCancel(handle, runId)
    override fun close(handle: Long): Int = MaxModelNative.nativeClose(handle)
}

/** Entry point for the Android binding. MAX is never selectable in the app. */
object MaxModelBinding {
    @Volatile
    internal var api: MaxModelApi = NativeMaxModelApi

    val available: Boolean get() = MaxModelNative.loaded

    fun verify(receipt: MaxModelReceipt): MaxVerification = api.verify(receipt)

    fun capability(receipt: MaxModelReceipt, loadProbePassed: Boolean = false): MaxModelCapability =
        api.capability(receipt, loadProbePassed)

    fun open(receipt: MaxModelReceipt): MaxOpenResult = api.open(receipt)
}

/**
 * One verified installation. Generation is single-flight; [cancel] may be called
 * from the sink, another thread or the UI and only affects the run that is
 * currently active. [close] refuses while a generation holds the lease.
 */
class MaxModelHandle internal constructor(
    private val id: Long,
    val receipt: MaxModelReceipt,
    private val api: MaxModelApi,
) {
    private val runIds = AtomicLong(0)
    private val running = AtomicBoolean(false)
    @Volatile private var activeRunId = 0L
    @Volatile private var closed = false

    val isClosed: Boolean get() = closed

    private fun busy() = MaxGenerationResult(
        MaxModelCode.BUSY,
        MaxGenerationPerformance(0, 0, 0.0, 0.0, 0.0, 0.0, MaxModelStatus.REJECTED, 0),
        "Generation is already in progress for this model.",
    )

    fun generate(
        prompt: String,
        maxTokens: Int = receipt.maxOutputTokens,
        temperature: Float = 0.7f,
        topP: Float = 0.9f,
        seed: Int = 0,
        sink: MaxTokenSink,
    ): MaxGenerationResult {
        check(!closed) { "The MAX model handle is closed." }
        require(prompt.isNotEmpty() && prompt.encodeToByteArray().size <= MaxModelLimits.MAX_PROMPT_BYTES) {
            "Prompt is outside the bounded UTF-8 request size."
        }
        require(maxTokens in 1..receipt.maxOutputTokens) { "Requested output exceeds the verified output budget." }
        require(temperature in 0f..2f && topP > 0f && topP <= 1f) {
            "Sampling parameters are outside the reviewed range."
        }
        if (!running.compareAndSet(false, true)) return busy()
        val runId = runIds.incrementAndGet()
        activeRunId = runId
        try {
            return api.generate(id, runId, prompt, maxTokens, temperature, topP, seed, sink)
        } finally {
            if (activeRunId == runId) activeRunId = 0L
            running.set(false)
        }
    }

    /** Cancels only the currently active run; returns false when idle or stale. */
    fun cancel(): Boolean {
        val runId = activeRunId
        return runId != 0L && api.cancel(id, runId)
    }

    fun close(): MaxCloseResult {
        if (closed) return MaxCloseResult.CLOSED
        return when (api.close(id)) {
            MaxModelCode.OK -> {
                closed = true
                MaxCloseResult.CLOSED
            }
            MaxModelCode.BUSY -> MaxCloseResult.BUSY
            else -> MaxCloseResult.INVALID
        }
    }
}
