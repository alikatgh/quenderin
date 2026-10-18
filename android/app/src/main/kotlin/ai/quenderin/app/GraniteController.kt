package ai.quenderin.app

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import ai.quenderin.core.GraniteArtifactProof
import ai.quenderin.core.GraniteMessage
import ai.quenderin.core.GraniteModelImporter
import ai.quenderin.core.NativeGraniteEngine
import ai.quenderin.core.SpecialistInferenceLease
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File
import java.util.UUID

data class GraniteUiState(val prompt: String = "", val messages: List<GraniteMessage> = emptyList(), val model: File? = null,
    val busy: Boolean = false, val progress: Float? = null, val error: String? = null,
    val status: String = "Import a converted Granite Switch 4.1 8B GGUF and its matching conversion record.")

class GraniteController(context: Context, private val suspendForSpecialist: () -> SpecialistInferenceLease) {
    private val context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val directory = File(this.context.filesDir, "granite-imports")
    private val preferences = this.context.getSharedPreferences("granite41", Context.MODE_PRIVATE)
    private val engine = NativeGraniteEngine(this.context.applicationInfo.nativeLibraryDir) { HyMemoryController.availableMemoryBytes(this.context) }
    private val mutable = MutableStateFlow(GraniteUiState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var closed = false
    init {
        preferences.getString("folder", null)?.takeIf { validFolder(it) }?.let { folder ->
            mutable.update { it.copy(model = File(File(directory, folder), "granite-switch-4.1-8b.gguf")) }
        }
    }
    fun blockReason(): String? = when {
        !NativeGraniteEngine.available -> "This build requires the verified native Prism text runtime."
        context.probeDeviceProfile().appMemoryBudgetGb < 32 -> "Granite Switch 4.1 8B needs at least 32 GiB of available app memory. Choose a smaller text model on this device."
        else -> null
    }
    fun prompt(value: String) { if (!state.value.busy && value.length <= 8192) mutable.update { it.copy(prompt = value) } }
    fun newConversation() { if (!state.value.busy) mutable.update { it.copy(messages = emptyList(), error = null) } }
    fun cancel() { engine.cancel(); job?.cancel() }
    fun close() {
        if (closed) return; closed = true; val pending = job; cancel()
        scope.launch { try { pending?.join() } finally { scope.cancel() } }
    }
    private fun run(status: String, timeout: Long, work: suspend () -> Unit) {
        if (closed || job != null) return
        mutable.update { it.copy(busy = true, error = null, status = status) }
        job = scope.launch {
            val current = currentCoroutineContext()
            val timer = scope.launch { delay(timeout); engine.cancel(); current[Job]?.cancel() }
            try { work() }
            catch (_: CancellationException) { mutable.update { it.copy(status = "Cancelled. Your question, conversation and completed import are kept.") } }
            catch (error: Exception) { mutable.update { it.copy(error = error.message?.take(2048) ?: "Granite operation failed.", status = "The operation did not finish. Your question and conversation are kept for retry.") } }
            finally { timer.cancel(); mutable.update { it.copy(busy = false, progress = null) }; job = null }
        }
    }
    private fun name(uri: Uri): String = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        require(cursor.moveToFirst()) { "Cannot read the selected file name." }
        cursor.getString(0)?.takeIf { it.length in 1..255 && '/' !in it && '\\' !in it && '\u0000' !in it }
            ?: error("Invalid selected file name.")
    } ?: error("Cannot read the selected file name.")
    fun importPair(uris: List<Uri>) {
        blockReason()?.let { reason -> mutable.update { it.copy(error = reason) }; return }
        if (uris.size != 2 || uris.distinct().size != 2) { mutable.update { it.copy(error = "Select exactly one GGUF and its matching GGUF.quenderin.json conversion record.") }; return }
        run("Copying and verifying the complete local conversion…", 7_200_000) {
            val proof = withContext(Dispatchers.IO) {
                val operation = currentCoroutineContext(); val names = uris.associateWith(::name)
                val model = names.entries.singleOrNull { it.value.endsWith(".gguf", true) } ?: error("Choose exactly one GGUF.")
                val record = names.entries.singleOrNull { it.value == model.value + ".quenderin.json" } ?: error("The conversion record must have the exact selected GGUF name plus .quenderin.json.")
                val receipt = context.contentResolver.openInputStream(record.key)?.use { input ->
                    val buffer = ByteArray(65_537); var count = 0
                    while (count < buffer.size) { operation.ensureActive(); val n = input.read(buffer, count, buffer.size - count); if (n < 0) break; count += n }
                    require(count <= 65_536) { "The conversion record exceeds 64 KiB." }; buffer.copyOf(count)
                } ?: error("Could not read the conversion record.")
                context.contentResolver.openInputStream(model.key)?.use { input ->
                    GraniteModelImporter.importPair(model.value, record.value, input, receipt, directory,
                        { fraction -> mutable.update { it.copy(progress = fraction) } }, { !operation.isActive })
                } ?: error("Could not read the selected GGUF.")
            }
            currentCoroutineContext().ensureActive()
            preferences.edit().putString("folder", File(proof.filePath).parentFile!!.name).apply()
            mutable.update { it.copy(model = File(proof.filePath), messages = emptyList(), status = "Complete local conversion and record verified. The selected originals are unchanged.") }
        }
    }
    fun ask() {
        blockReason()?.let { reason -> mutable.update { it.copy(error = reason) }; return }
        val snapshot = state.value; val question = snapshot.prompt.trim(); val model = snapshot.model
        if (model == null || question.isEmpty() || question.toByteArray(Charsets.UTF_8).size > 8192 || '\u0000' in question || snapshot.messages.size >= 30) {
            mutable.update { it.copy(error = "Import the model and enter a question of 1–8,192 UTF-8 bytes, or start a new conversation if this one is full.") }; return
        }
        val history = snapshot.messages + GraniteMessage(GraniteMessage.Role.USER, question)
        run("Verifying the local model, then answering…", 600_000) {
            val final = withContext(Dispatchers.IO) {
                val operation = currentCoroutineContext(); val lease = suspendForSpecialist()
                try {
                    operation.ensureActive()
                    val proof = GraniteArtifactProof.verify(model) { !operation.isActive }
                    operation.ensureActive(); engine.answer(proof, history) { !operation.isActive }
                } finally {
                    // Blocking answer has joined/unloaded its specialist before this restoration.
                    withContext(NonCancellable) { lease.resume() }
                }
            }
            currentCoroutineContext().ensureActive()
            mutable.update { it.copy(messages = history + GraniteMessage(GraniteMessage.Role.ASSISTANT, final), prompt = "", status = "Final text answer from the imported Granite conversion.") }
        }
    }
    private fun validFolder(name: String): Boolean = Regex("[0-9a-f]{64}").matches(name) || runCatching { UUID.fromString(name) }.isSuccess ||
        (name.length == 101 && Regex("[0-9a-f]{64}-").matches(name.take(65)) && runCatching { UUID.fromString(name.drop(65)) }.isSuccess)
}
