package ai.quenderin.core

import java.io.File
import java.util.concurrent.CancellationException

data class ImageGenerationRequest(
    val model: ImageModel, val directory: File, val prompt: String, val output: File, val seed: Long = 0,
    val isCancelled: () -> Boolean = { false },
)

interface ImageGenerationEngine {
    val available: Boolean
    /** Blocking native work: call on an IO worker. Progress may arrive on any native thread. */
    fun generate(request: ImageGenerationRequest, progress: (Float) -> Unit): File
    fun cancel()
}

fun interface NativeImageProgress { fun onProgress(step: Int, steps: Int) }

object NativeImageGenerationBridge {
    val available: Boolean by lazy {
        try { System.loadLibrary("quenderin_diffusion_jni"); abi() == 1 }
        catch (_: UnsatisfiedLinkError) { false }
        catch (_: SecurityException) { false }
    }
    @JvmStatic external fun abi(): Int
    @JvmStatic external fun create(): Long
    @JvmStatic external fun generate(
        handle: Long, modelKind: Int, diffusionPath: String, textEncoderPath: String,
        vaePath: String, tokenizerPath: String?, prompt: String, negativePrompt: String?,
        outputPath: String, width: Int, height: Int, steps: Int, threads: Int, seed: Long,
        progress: NativeImageProgress?,
    ): String?
    @JvmStatic external fun cancel(handle: Long): Int
    @JvmStatic external fun destroy(handle: Long): Int
}

class NativeImageGenerationEngine(private val budget: () -> ImageResourceBudget) : ImageGenerationEngine {
    private val lock = Any()
    private var handle = 0L
    private var running = false
    @Volatile private var cancelled = false
    override val available: Boolean get() = NativeImageGenerationBridge.available

    override fun generate(request: ImageGenerationRequest, progress: (Float) -> Unit): File {
        check(available) { "This build does not include the local image engine." }
        request.model.validate()
        require(request.prompt.isNotBlank() && request.prompt.toByteArray().size <= 8192 && !request.prompt.contains('\u0000')) {
            "Enter a scene description of at most 8,192 bytes."
        }
        require(request.seed >= 0 && request.output.isAbsolute && !request.output.exists()) { "Choose a new image output path." }
        budget().blockReason(request.model, installing = false)?.let { error(it) }
        synchronized(lock) {
            check(!running) { "An image is already being generated." }
            running = true
            cancelled = false
        }
        try {
            ImageModelFiles.verify(request.model, request.directory) { cancelled || request.isCancelled() }
            if (cancelled || request.isCancelled()) throw CancellationException("Image generation cancelled")
            budget().blockReason(request.model, installing = false)?.let { error(it) }
            synchronized(lock) {
                handle = NativeImageGenerationBridge.create()
                check(handle != 0L) { "The local image engine could not start." }
                if (cancelled || request.isCancelled()) NativeImageGenerationBridge.cancel(handle)
            }
            fun component(role: String): String = request.model.components.first { it.role == role }
                .let { File(request.directory, it.localFilename).absolutePath }
            val error = NativeImageGenerationBridge.generate(
                handle, request.model.modelKind, component("diffusion"), component("text_encoder"), component("vae"),
                if (request.model.modelKind == 1) null else component("tokenizer"), request.prompt, null,
                request.output.absolutePath, request.model.defaults.width, request.model.defaults.height,
                request.model.defaults.steps, Runtime.getRuntime().availableProcessors().coerceIn(1, 8), request.seed,
                NativeImageProgress { step, steps -> if (steps > 0) progress((step.toFloat() / steps).coerceIn(0f, 1f)) },
            )
            if (cancelled || request.isCancelled()) throw CancellationException("Image generation cancelled")
            check(error == null) { error.orEmpty() }
            request.output.inputStream().use { input ->
                val signature = ByteArray(8)
                check(input.read(signature) == 8 && signature.contentEquals(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10))) {
                    "The image engine did not produce a valid PNG."
                }
            }
            return request.output
        } finally {
            synchronized(lock) {
                if (handle != 0L) NativeImageGenerationBridge.destroy(handle)
                handle = 0L
                running = false
            }
        }
    }

    override fun cancel() {
        synchronized(lock) {
            cancelled = true
            if (handle != 0L) NativeImageGenerationBridge.cancel(handle)
        }
    }
}
