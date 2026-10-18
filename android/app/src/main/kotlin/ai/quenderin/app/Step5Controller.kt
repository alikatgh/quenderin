package ai.quenderin.app

import ai.quenderin.core.Step5Client
import ai.quenderin.core.Step5Contract
import ai.quenderin.core.Step5Message
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class Step5UiState(val endpoint: String = "", val consent: Boolean = false, val prompt: String = "", val messages: List<Step5Message> = emptyList(),
    val busy: Boolean = false, val connected: Boolean = false, val status: String = "Enter your CUDA-host gateway origin and check its pinned backend.", val error: String? = null)

class Step5Controller(private val client: Step5Client = Step5Client({ Step5OkHttpTransport() }), private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) {
    private var job: Job? = null
    private val mutable = MutableStateFlow(Step5UiState())
    val state = mutable.asStateFlow()
    fun endpoint(value: String) { if (!state.value.busy && value.length <= 2048) mutable.update { it.copy(endpoint = value, consent = false, connected = false) } }
    fun consent(value: Boolean) { if (!state.value.busy) mutable.update { it.copy(consent = value) } }
    fun prompt(value: String) { if (!state.value.busy && value.length <= 8192) mutable.update { it.copy(prompt = value) } }
    fun validEndpoint(): Boolean = runCatching { Step5Contract.endpoint(state.value.endpoint) }.isSuccess
    fun cancel() { client.cancel(); job?.cancel() }
    fun clear() { if (!state.value.busy) mutable.update { it.copy(messages = emptyList(), error = null, status = "Conversation cleared. Your host and unsent prompt are kept in memory.") } }
    private fun run(status: String, work: suspend () -> Unit) {
        if (job != null) return
        mutable.update { it.copy(busy = true, error = null, status = status) }
        job = scope.launch {
            try { work() }
            catch (_: CancellationException) { mutable.update { it.copy(status = "Request cancelled. Your prompt and conversation are kept.") } }
            catch (error: Exception) { mutable.update { it.copy(error = error.message?.take(2048) ?: "Step 5 request failed.", status = "Request did not finish. Your prompt and conversation are kept.") } }
            finally { mutable.update { it.copy(busy = false) }; job = null }
        }
    }
    fun check() {
        val host = state.value.endpoint
        run("Checking the pinned Step 5 gateway…") {
            withContext(Dispatchers.IO) { client.check(host) }; currentCoroutineContext().ensureActive()
            mutable.update { it.copy(connected = true, status = "Pinned CUDA backend and complete verified artifacts are ready.") }
        }
    }
    fun send() {
        val snapshot = state.value
        if (!snapshot.consent) { mutable.update { it.copy(error = "Confirm that this conversation may be sent to the selected CUDA host.") }; return }
        if (snapshot.messages.size + 2 > 16) { mutable.update { it.copy(error = "This conversation reached its message limit. Clear it explicitly before asking another question.") }; return }
        val messages = snapshot.messages + Step5Message("user", snapshot.prompt)
        try { Step5Contract.messages(messages) } catch (error: Exception) { mutable.update { it.copy(error = error.message) }; return }
        run("Waiting for the Step 5 CUDA host…") {
            val answer = withContext(Dispatchers.IO) { client.answer(snapshot.endpoint, messages) }; currentCoroutineContext().ensureActive()
            mutable.update { it.copy(messages = messages + Step5Message("assistant", answer.text), prompt = if (it.prompt == snapshot.prompt) "" else it.prompt,
                connected = true, status = if (answer.truncated) "Answer reached the host's 1,024-token limit. Nothing was retried automatically." else "Final answer received from your CUDA host.") }
        }
    }
}
