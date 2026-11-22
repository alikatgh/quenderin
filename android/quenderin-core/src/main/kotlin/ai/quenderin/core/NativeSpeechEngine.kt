package ai.quenderin.core

import java.io.File
import java.util.concurrent.CancellationException

data class SpeechTranscriptionRequest(
    val model: SpeechModel,
    val directory: File,
    val pcm16: ShortArray,
    val vad: SpeechVadModel? = null,
    val language: String? = null,
    val prompt: String? = null,
    val formatting: SpeechFormattingOptions = SpeechFormattingOptions(),
    val threads: Int = Runtime.getRuntime().availableProcessors().coerceIn(1, 8),
    val translate: Boolean = false,
    val timestamps: Boolean = false,
    val isCancelled: () -> Boolean = { false },
) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

data class SpeechTranscriptionResult(
    val text: String,
    val rawText: String,
    val modelId: String,
)

interface SpeechTranscriptionEngine {
    val available: Boolean
    fun transcribe(request: SpeechTranscriptionRequest): SpeechTranscriptionResult
    fun cancel()
}

object NativeSpeechBridge {
    val available: Boolean by lazy {
        try {
            System.loadLibrary("quenderin_speech_jni")
            abi() == 1
        } catch (_: UnsatisfiedLinkError) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    @JvmStatic external fun abi(): Int
    @JvmStatic external fun create(): Long
    @JvmStatic external fun cancel(handle: Long): Int
    @JvmStatic external fun destroy(handle: Long): Int
    @JvmStatic external fun transcribePcm(
        handle: Long,
        modelPath: String,
        vadPath: String?,
        samples: ShortArray,
        count: Int,
        language: String?,
        prompt: String?,
        vocabulary: Array<String>?,
        threads: Int,
        translate: Boolean,
        timestamps: Boolean,
    ): ByteArray?
}

class NativeSpeechEngine : SpeechTranscriptionEngine {
    private val lock = Any()
    private var handle = 0L
    private var running = false
    @Volatile private var cancelled = false

    override val available: Boolean get() = NativeSpeechBridge.available

    override fun transcribe(request: SpeechTranscriptionRequest): SpeechTranscriptionResult {
        check(available) { "This build does not include the native speech engine." }
        request.model.validate()
        require(request.pcm16.isNotEmpty() && request.pcm16.size <= 32_000_000) {
            "Audio sample buffer must contain between 1 and 32,000,000 samples (16 kHz mono 16-bit)."
        }
        require(request.threads in 1..8) { "Speech threads must be between 1 and 8." }
        request.prompt?.let {
            require(!it.contains('\u0000') && it.toByteArray(Charsets.UTF_8).size <= 8192) {
                "Speech prompt must be at most 8,192 bytes without NUL."
            }
        }
        synchronized(lock) {
            check(!running) { "A speech transcription is already running." }
            running = true
            cancelled = false
        }
        try {
            SpeechModelFiles.verify(request.model, request.directory, request.vad) {
                cancelled || request.isCancelled()
            }
            if (cancelled || request.isCancelled()) {
                throw CancellationException("Speech transcription cancelled")
            }
            synchronized(lock) {
                handle = NativeSpeechBridge.create()
                check(handle != 0L) { "The native speech engine could not start." }
                if (cancelled || request.isCancelled()) {
                    NativeSpeechBridge.cancel(handle)
                }
            }
            val modelFile = File(request.directory, requireNotNull(request.model.localFilename))
            val vadFile = request.vad?.let { File(request.directory, it.localFilename) }
            val vocabTerms = request.formatting.vocabulary
                .map { it.term.trim() }
                .filter { it.isNotEmpty() }
                .take(100)
                .toTypedArray()

            val utf8Bytes = NativeSpeechBridge.transcribePcm(
                handle,
                modelFile.absolutePath,
                vadFile?.absolutePath,
                request.pcm16,
                request.pcm16.size,
                request.language,
                request.prompt,
                if (vocabTerms.isEmpty()) null else vocabTerms,
                request.threads,
                request.translate,
                request.timestamps,
            )
            if (cancelled || request.isCancelled()) {
                throw CancellationException("Speech transcription cancelled")
            }
            val decodedBytes = checkNotNull(utf8Bytes) { "Local speech transcription failed." }
            val rawText = String(decodedBytes, Charsets.UTF_8)
            val formatted = SpokenTextFormatter.format(rawText, request.formatting)
            return SpeechTranscriptionResult(
                text = formatted,
                rawText = rawText,
                modelId = request.model.id,
            )
        } finally {
            synchronized(lock) {
                if (handle != 0L) NativeSpeechBridge.destroy(handle)
                handle = 0L
                running = false
            }
        }
    }

    override fun cancel() {
        synchronized(lock) {
            cancelled = true
            if (handle != 0L) NativeSpeechBridge.cancel(handle)
        }
    }
}
