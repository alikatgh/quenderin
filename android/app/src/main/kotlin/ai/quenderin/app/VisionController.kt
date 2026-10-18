package ai.quenderin.app

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import ai.quenderin.core.NativeVisionEngine
import ai.quenderin.core.VisionModelInstaller
import ai.quenderin.core.VisionModels
import ai.quenderin.core.VisionSelectedImage
import ai.quenderin.core.SpecialistInferenceLease
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

data class VisionUiState(val selectedID: String = VisionModels.all.first().id, val prompt: String = "", val image: File? = null,
    val imageLabel: String = "No still image selected", val answer: String = "", val busy: Boolean = false, val installed: Boolean = false,
    val progress: Float? = null, val status: String = "Choose a vision preset and one still image.", val error: String? = null) {
    val model get() = VisionModels.model(selectedID)!!
}

class VisionController(context: Context, private val suspendForSpecialist: () -> SpecialistInferenceLease = { error("The app has not supplied exclusive specialist engine coordination.") }) {
    private val context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val installer = VisionModelInstaller(File(this.context.filesDir, "vision-models"))
    private val inputs = File(this.context.filesDir, "vision-input-${UUID.randomUUID()}")
    private val engine = NativeVisionEngine(this.context.applicationInfo.nativeLibraryDir)
    private val mutable = MutableStateFlow(VisionUiState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var closed = false
    init { refresh() }
    private fun memory(): Long {
        val info = ActivityManager.MemoryInfo(); (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
        return minOf(info.availMem, (context.probeDeviceProfile().appMemoryBudgetGb * 1_073_741_824).toLong())
    }
    fun blockReason(): String? {
        if (!NativeVisionEngine.available) return "This build does not include the pinned native vision runtime."
        return runCatching { VisionModelInstaller.checkResources(state.value.model, memory(), context.filesDir.usableSpace) }.exceptionOrNull()?.message
    }
    fun runtimeAvailable(): Boolean = NativeVisionEngine.available
    fun refresh() { mutable.update { it.copy(installed = installer.hasComponents(it.model)) } }
    fun select(id: String) { if (!state.value.busy && VisionModels.model(id) != null) { mutable.update { it.copy(selectedID = id, answer = "", error = null) }; refresh() } }
    fun prompt(value: String) { if (!state.value.busy && value.length <= 8192) mutable.update { it.copy(prompt = value) } }
    fun cancel() { installer.cancel(); engine.cancel(); job?.cancel() }
    fun close() {
        if (closed) return; closed = true; val pending = job; cancel()
        scope.launch { try { pending?.join(); withContext(Dispatchers.IO) { engine.close(); inputs.listFiles()?.forEach { it.delete() }; inputs.delete() } } finally { scope.cancel() } }
    }
    private fun run(status: String, timeout: Long, work: suspend () -> Unit) {
        if (closed || job != null) return
        installer.prepare(); mutable.update { it.copy(busy = true, error = null, status = status) }
        job = scope.launch {
            val current = currentCoroutineContext()
            val timer = scope.launch { delay(timeout); installer.cancel(); engine.cancel(); current[Job]?.cancel() }
            try { work() }
            catch (_: CancellationException) { mutable.update { it.copy(status = "Cancelled. Your question, selected image and verified components are kept.") } }
            catch (error: Exception) { mutable.update { it.copy(error = error.message?.take(2048) ?: "Vision operation failed.", status = "The operation did not finish. Your question and image are kept for retry.") } }
            finally { timer.cancel(); mutable.update { it.copy(busy = false, progress = null) }; job = null }
        }
    }
    fun chooseImage(uri: Uri) {
        run("Checking the selected still image…", 30_000) {
            val pending = AtomicReference<File?>()
            try {
                val chosen = withContext(Dispatchers.IO) {
                    val operation = currentCoroutineContext()
                    context.contentResolver.openInputStream(uri)?.use { VisionSelectedImage.copy(it, inputs) { !operation.isActive }.also(pending::set) }
                        ?: error("Could not read the selected image.")
                }
                currentCoroutineContext().ensureActive(); state.value.image?.delete()
                mutable.update { it.copy(image = chosen, imageLabel = "Selected PNG or JPEG · ${chosen.length()} bytes", answer = "", status = "Still image selected. Its original remains unchanged.") }
                pending.set(null)
            } finally { pending.getAndSet(null)?.delete() }
        }
    }
    fun install() {
        blockReason()?.let { mutable.update { state -> state.copy(error = it) }; return }
        val model = state.value.model
        run("Installing and verifying both pinned vision components…", 7_200_000) {
            withContext(Dispatchers.IO) { installer.install(model, memory(), context.filesDir.usableSpace) { progress -> mutable.update { it.copy(progress = progress) } } }
            currentCoroutineContext().ensureActive(); mutable.update { it.copy(installed = true, status = "Complete model and projector verified.") }
        }
    }
    fun ask() {
        if (!runtimeAvailable()) { mutable.update { it.copy(error = "This build does not include the pinned native vision runtime.") }; return }
        val snapshot = state.value; val image = snapshot.image
        if (image == null || snapshot.prompt.isBlank() || snapshot.prompt.toByteArray(Charsets.UTF_8).size > 8192 || '\u0000' in snapshot.prompt) {
            mutable.update { it.copy(error = "Choose a still image and enter a question of 1–8,192 UTF-8 bytes.") }; return
        }
        run("Verifying components, then loading the still-image model…", 900_000) {
            val answer = withContext(Dispatchers.IO) {
                val lease = suspendForSpecialist()
                try {
                    currentCoroutineContext().ensureActive()
                    val files = installer.verify(snapshot.model, memory(), context.filesDir.usableSpace); currentCoroutineContext().ensureActive()
                    VisionSelectedImage.validate(image)
                    val freshMemory = memory(); VisionModelInstaller.checkResources(snapshot.model, freshMemory, context.filesDir.usableSpace)
                    engine.answer(snapshot.model, files.modelFile.path, files.projectorFile.path, image.path, snapshot.prompt, freshMemory)
                } finally {
                    // Blocking answer has joined/freed its native worker before returning.
                    withContext(NonCancellable) { lease.resume() }
                }
            }
            currentCoroutineContext().ensureActive()
            require(answer.isNotBlank() && answer.toByteArray(Charsets.UTF_8).size <= 262_144 && '\u0000' !in answer
                && !Regex("</?(?:think|tool_call)|<\\|(?:im_start|im_end|channel)|<｜", RegexOption.IGNORE_CASE).containsMatchIn(answer)) { "The runtime did not return a complete final answer." }
            mutable.update { it.copy(answer = answer, status = "Final answer from the selected still-image model.") }
        }
    }
}
