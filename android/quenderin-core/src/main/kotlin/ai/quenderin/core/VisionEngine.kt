package ai.quenderin.core

import java.io.File

/** Separate short-lived vision context. close/cancel never free a running worker's handle. */
class NativeVisionEngine internal constructor(private val nativeLibDir: String, private val currentMemoryBytes: () -> Long) : AutoCloseable {
    constructor(nativeLibDir: String = "") : this(nativeLibDir, NativeModelResources::availableMemoryBytes)
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val state = Object()
    private var busy = false
    private var closed = false
    private var cancelled = false
    private var handle = 0L
    fun cancel() = synchronized(state) {
        if (busy) { cancelled = true; if (handle != 0L) nativeCancel(handle) }
    }
    override fun close() = synchronized(state) {
        closed = true
        if (busy) { cancelled = true; if (handle != 0L) nativeCancel(handle) }
        while (busy) state.wait()
    }
    fun answer(model: VisionModelDescriptor, mainPath: String, projectorPath: String, imagePath: String,
               prompt: String, availableMemoryBytes: Long): String {
        check(available) { "The pinned native vision runtime is unavailable in this build." }
        validate(model, mainPath, projectorPath, imagePath, prompt, availableMemoryBytes)
        synchronized(state) { check(!busy && !closed) { "Vision is already running or has been closed." }; busy = true; cancelled = false }
        try {
            check(currentMemoryBytes() >= model.minimumMemoryBytes) { "Current available memory is insufficient for the whole vision model." }
            val native = nativeCreate(nativeLibDir)
            check(native != 0L) { "Unable to create the vision engine." }
            synchronized(state) { handle = native; if (cancelled) nativeCancel(native) }
            nativeLoad(native, model.id, mainPath, projectorPath)
            synchronized(state) { check(!cancelled) { "Vision was cancelled." } }
            val answer = nativeGenerate(native, imagePath, prompt)
            synchronized(state) { check(!cancelled) { "Vision was cancelled." } }
            check(answer.toByteArray(Charsets.UTF_8).size <= 65_536 && answer.isNotBlank()) { "Native vision returned an invalid answer." }
            return answer
        } finally {
            synchronized(state) {
                if (handle != 0L) { nativeFree(handle); handle = 0L }
                busy = false; state.notifyAll()
            }
        }
    }
    private external fun nativeCreate(nativeLibDir: String): Long
    private external fun nativeLoad(handle: Long, modelId: String, mainPath: String, projectorPath: String)
    private external fun nativeGenerate(handle: Long, imagePath: String, prompt: String): String
    private external fun nativeCancel(handle: Long)
    private external fun nativeFree(handle: Long)
    companion object {
        internal const val REVISION = "e8fd209c975c80aa7fb36a8423571ff3b1b7e955"
        internal const val PATCH_SHA256 = "417a4d19ed4e05625cd4bc3ec269bf1a4331e8dd9263956b95e86b6158f938a9"
        @JvmStatic private external fun nativeIdentity(): String
        val available: Boolean by lazy {
            runCatching { System.loadLibrary("quenderin_llama"); nativeIdentity() == "1:$REVISION:$PATCH_SHA256" }.getOrDefault(false)
        }
        internal fun validate(model: VisionModelDescriptor, mainPath: String, projectorPath: String, imagePath: String,
                              prompt: String, availableMemoryBytes: Long) {
            val pinned = VisionModels.model(model.id)
            require(pinned != null && model == pinned && model.artifacts.size == 2 && availableMemoryBytes >= model.minimumMemoryBytes) {
                "A complete pinned vision model and sufficient available memory are required."
            }
            val main = model.artifacts.single { it.role == "model" }; val projector = model.artifacts.single { it.role == "projector" }
            require(File(mainPath).name == main.filename && File(projectorPath).name == projector.filename && mainPath != projectorPath) { "Vision component paths do not match the pinned manifest." }
            for (path in listOf(mainPath, projectorPath, imagePath)) {
                val file = File(path)
                require(file.isAbsolute && path.toByteArray(Charsets.UTF_8).size <= 16_384 && '\u0000' !in path && file.canonicalFile == file.absoluteFile) {
                    "Vision inputs must be local absolute paths without symbolic links."
                }
            }
            require(prompt.isNotBlank() && prompt.toByteArray(Charsets.UTF_8).size <= 32_768 && '\u0000' !in prompt) { "Enter a question of 1–32768 UTF-8 bytes." }
        }
    }
}
