package ai.quenderin.app

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import ai.quenderin.core.ImageGenerationEngine
import ai.quenderin.core.ImageGenerationRequest
import ai.quenderin.core.ImageModel
import ai.quenderin.core.ImageResourceBudget
import ai.quenderin.core.NativeImageGenerationEngine
import ai.quenderin.core.SpecialistInferenceLease
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

data class ImageGenerationUiState(
    val models: List<ImageModel> = emptyList(), val selectedID: String = "moss-image-sft",
    val prompt: String = "", val publisherTermsAccepted: Boolean = false, val busy: Boolean = false,
    val progress: Float? = null, val installed: Boolean = false,
    val status: String = "Choose a model to create an image locally.", val error: String? = null,
    val output: File? = null,
) { val selected: ImageModel? get() = models.firstOrNull { it.id == selectedID } }

class ImageGenerationController(context: Context, engine: ImageGenerationEngine? = null, private val suspendForSpecialist: () -> SpecialistInferenceLease = { error("The app has not supplied exclusive specialist engine coordination.") }) {
    private val context = context.applicationContext
    private val installer = ImageModelInstaller(this.context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val engine: ImageGenerationEngine = engine ?: NativeImageGenerationEngine(::budget)
    private val mutable = MutableStateFlow(ImageGenerationUiState())
    val state = mutable.asStateFlow()
    private var job: Job? = null

    init {
        try {
            val models = this.context.assets.open("image-model-catalog.json").use { ImageModelJSON.decode(it.readBytes()) }
            val selected = models.firstOrNull { it.id == "moss-image-sft" } ?: models.first()
            mutable.value = mutable.value.copy(models = models, selectedID = selected.id, installed = hasComponents(selected))
        } catch (error: Exception) { mutable.update { it.copy(error = error.message ?: "Image catalog unavailable") } }
    }

    fun budget(): ImageResourceBudget {
        val memory = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        return ImageResourceBudget(memory.availMem, context.filesDir.usableSpace)
    }
    // Exact remaining-byte preflight follows checksum verification inside the installer worker.
    fun fitReason(installing: Boolean): String? = state.value.selected?.let {
        budget().blockReason(it, installing, remainingDownloadBytes = if (installing) 0L else null)
    }
    fun select(id: String) {
        if (state.value.busy) return
        val selected = state.value.models.firstOrNull { it.id == id } ?: return
        mutable.update { it.copy(selectedID = id, publisherTermsAccepted = false, installed = hasComponents(selected), error = null) }
    }
    fun setPrompt(prompt: String) { if (!state.value.busy) mutable.update { it.copy(prompt = prompt) } }
    fun acceptPublisherTerms(accepted: Boolean) { if (!state.value.busy) mutable.update { it.copy(publisherTermsAccepted = accepted) } }

    fun install(imported: List<Uri> = emptyList()) {
        val snapshot = state.value
        val model = snapshot.selected ?: return
        if (snapshot.busy) return
        if (!engine.available) { reportError("This build does not include the local image engine."); return }
        val budget = budget()
        budget.blockReason(model, false)?.let { reportError(it); return }
        installer.prepare()
        mutable.update { it.copy(busy = true, progress = 0f, error = null, status = "Installing and verifying model components…") }
        job = scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    installer.install(model, budget, imported, snapshot.publisherTermsAccepted) { progress ->
                        mutable.update { it.copy(progress = progress) }
                    }
                }
                mutable.update { it.copy(installed = true, status = "Complete model installed and verified.") }
            } catch (_: CancellationException) { mutable.update { it.copy(status = "Installation cancelled. Verified components are kept for retry.") } }
            catch (error: Exception) { reportError(error.message ?: "Installation did not finish.") }
            finally { mutable.update { it.copy(busy = false, progress = null) }; job = null }
        }
    }

    fun generate() {
        val snapshot = state.value
        val model = snapshot.selected ?: return
        if (snapshot.busy || !snapshot.installed) return
        if (!engine.available) { reportError("This build does not include the local image engine."); return }
        if (model.requiresPublisherAccess && !snapshot.publisherTermsAccepted) { reportError("Confirm that you have reviewed and accepted the publisher terms."); return }
        mutable.update { it.copy(busy = true, progress = null, error = null, status = "Verifying components and loading the model…") }
        job = scope.launch {
            try {
                val image = withContext(Dispatchers.IO) {
                    val generationContext = currentCoroutineContext()
                    val lease = suspendForSpecialist()
                    try {
                        generationContext.ensureActive()
                        budget().blockReason(model, false)?.let { error(it) }
                        val outputs = File(context.filesDir, "created-images").canonicalFile
                        check(outputs.mkdirs() || outputs.isDirectory) { "Could not create image output folder" }
                        engine.generate(ImageGenerationRequest(model, File(installer.directory, model.id), snapshot.prompt,
                            File(outputs, "Quenderin-${UUID.randomUUID()}.png"), isCancelled = { !generationContext.isActive })) { progress ->
                            mutable.update { it.copy(progress = progress, status = "Generating image…") }
                        }
                    } finally {
                        withContext(NonCancellable) { lease.resume() }
                    }
                }
                mutable.update { it.copy(output = image, status = "Image created locally.") }
            } catch (_: CancellationException) { mutable.update { it.copy(status = "Generation cancelled.") } }
            catch (error: Exception) { reportError(error.message ?: "Generation did not finish.") }
            finally { mutable.update { it.copy(busy = false, progress = null) }; job = null }
        }
    }

    fun cancel() { mutable.update { it.copy(status = "Stopping… Model loading must return before cancellation finishes.") }; installer.cancel(); engine.cancel(); job?.cancel() }
    fun close() { cancel(); scope.cancel() }
    fun reportError(message: String) { mutable.update { it.copy(error = message) } }
    fun reportSaved() { mutable.update { it.copy(status = "Image saved.", error = null) } }
    private fun hasComponents(model: ImageModel): Boolean = model.components.all { part ->
        File(File(installer.directory, model.id), part.localFilename).let { it.isFile && it.length() == part.bytes }
    }
}
