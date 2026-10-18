package ai.quenderin.app

import android.app.ActivityManager
import android.content.Context
import ai.quenderin.core.HyApprovedMemoryStore
import ai.quenderin.core.HyMemory
import ai.quenderin.core.HyMemoryInferencePort
import ai.quenderin.core.HyMemoryInferenceRequest
import ai.quenderin.core.HyMemoryInstaller
import ai.quenderin.core.HyMemoryProposal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.NonCancellable
import ai.quenderin.core.SpecialistInferenceLease
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

data class HyMemoryUiState(val conversation: String = "", val installed: Boolean = false, val busy: Boolean = false,
    val progress: Float? = null, val proposals: List<HyMemoryProposal> = emptyList(), val selected: Set<String> = emptySet(),
    val status: String = "Choose a conversation. Nothing is saved automatically.", val error: String? = null)

class HyMemoryController(context: Context, val inference: HyMemoryInferencePort, private val suspendForSpecialist: () -> SpecialistInferenceLease = { error("The app has not supplied exclusive specialist engine coordination.") }) {
    private val context = context.applicationContext
    private val installer = HyMemoryInstaller(File(this.context.filesDir, "specialists/hy-memory"))
    private val store = HyApprovedMemoryStore(File(this.context.filesDir, "approved-memories"))
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null
    private val mutable = MutableStateFlow(HyMemoryUiState(installed = installer.isInstalled()))
    val state = mutable.asStateFlow()
    companion object {
        fun availableMemoryBytes(context: Context): Long {
            val memory = ActivityManager.MemoryInfo()
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
            val budget = (context.probeDeviceProfile().appMemoryBudgetGb * 1_073_741_824).toLong()
            return minOf(memory.availMem, budget)
        }
    }
    fun blockReason(): String? = inference.unavailableReason ?: if (availableMemoryBytes(context) < HyMemory.MINIMUM_MEMORY_BYTES) "Requires at least 32 GiB of available app memory for the complete specialist." else null
    fun runtimeUnavailableReason(): String? = inference.unavailableReason
    fun edit(input: String) { if (!state.value.busy && input.length <= 8192) mutable.update { it.copy(conversation = input) } }
    fun select(id: String, selected: Boolean) {
        if (state.value.busy || state.value.proposals.none { it.id == id && !it.saved }) return
        mutable.update { it.copy(selected = if (selected) it.selected + id else it.selected - id) }
    }
    fun cancel() { installer.cancel(); inference.cancel(); job?.cancel() }
    private fun run(status: String, timeout: Long = 60_000, work: suspend () -> Unit) {
        if (job != null) return
        installer.prepare(); mutable.update { it.copy(busy = true, error = null, status = status) }
        job = scope.launch {
            val timer = scope.launch { delay(timeout); cancel() }
            try { work() }
            catch (_: CancellationException) { mutable.update { it.copy(status = "Operation cancelled. Your conversation and existing memories are kept.") } }
            catch (error: Exception) { mutable.update { it.copy(error = error.message?.take(2048) ?: "Hy-Memory operation failed.", status = "Operation did not finish. You can retry.") } }
            finally { timer.cancel(); mutable.update { it.copy(busy = false, progress = null) }; job = null }
        }
    }
    fun install() {
        blockReason()?.let { reason -> mutable.update { it.copy(error = reason) }; return }
        run("Installing and verifying the complete pinned specialist…", 3_600_000) {
            withContext(Dispatchers.IO) { installer.install(availableMemoryBytes(context), context.filesDir.usableSpace) { fraction -> mutable.update { it.copy(progress = fraction) } } }
            mutable.update { it.copy(installed = true, status = "Pinned specialist installed. The answer model is unchanged.") }
        }
    }
    fun propose() {
        runtimeUnavailableReason()?.let { reason -> mutable.update { it.copy(error = reason) }; return }
        val input = state.value.conversation
        run("Verifying the specialist and extracting proposals…") {
            val facts = withContext(Dispatchers.IO) {
                val coroutine = currentCoroutineContext()
                val lease = suspendForSpecialist()
                try {
                    coroutine.ensureActive(); val proof = installer.verify(availableMemoryBytes(context), context.filesDir.usableSpace)
                    val output = StringBuilder()
                    inference.generate(HyMemoryInferenceRequest(proof, HyMemory.prompt(input))) { chunk ->
                        coroutine.ensureActive()
                        require(chunk.toByteArray(Charsets.UTF_8).size <= 65_536 && output.toString().toByteArray(Charsets.UTF_8).size + chunk.toByteArray(Charsets.UTF_8).size <= 65_536) { "Hy-Memory exceeded its bounded proposal budget." }
                        output.append(chunk)
                    }
                    coroutine.ensureActive(); HyMemory.parse(output.toString())
                } finally {
                    // generate returns only after its native context is released.
                    withContext(NonCancellable) { inference.cancel(); lease.resume() }
                }
            }
            mutable.update { it.copy(proposals = facts.map { text -> HyMemoryProposal(text = text) }, selected = emptySet(), status = if (facts.isEmpty()) "No suitable explicit facts were proposed. Nothing was saved." else "Review each proposal. Every proposal starts unchecked.") }
        }
    }
    fun approve() {
        val chosen = state.value.selected
        if (chosen.isEmpty()) return
        run("Saving only the selected proposals…") {
            for (proposal in state.value.proposals.filter { it.id in chosen && !it.saved }) {
                currentCoroutineContext().ensureActive(); withContext(Dispatchers.IO) { store.save(proposal) }
                mutable.update { it.copy(proposals = it.proposals.map { row -> if (row.id == proposal.id) row.copy(saved = true) else row }) }
            }
            mutable.update { it.copy(selected = emptySet(), status = "Selected proposals saved to the private approved-memory bank.") }
        }
    }
}
