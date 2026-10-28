package ai.quenderin.app.contentreport

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ContentReportUiState(
    val visible: Boolean = false,
    val selectionId: String? = null,
    val draft: ReportDraft? = null,
    val truncated: Boolean = false,
    val busy: Boolean = false,
    val result: ReportResult? = null,
)

/** One bounded selected report in RAM. Activity recreation retains the same request owner, draft,
 * ID and receipt. Nothing is put in SavedStateHandle/Bundle or replayed after process death. */
class ContentReportViewModel(private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO) : ViewModel() {
    private val mutableState = MutableStateFlow(ContentReportUiState())
    val state = mutableState.asStateFlow()
    private var messageKey: String? = null
    private var sent: PreparedReport? = null

    fun open(response: String, source: ReportSource, appVersion: String): Boolean {
        if (mutableState.value.busy) return false
        val key = source.wire + MessageDigest.getInstance("SHA-256").digest(response.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        if (key == messageKey && mutableState.value.draft != null) {
            mutableState.value = mutableState.value.copy(visible = true)
            return true
        }
        val excerpt = ContentReportProtocol.initialExcerpt(response)
        messageKey = key
        sent = null
        mutableState.value = ContentReportUiState(visible = true, selectionId = UUID.randomUUID().toString(),
            draft = ReportDraft(source, appVersion, excerpt), truncated = excerpt != response)
        return true
    }

    /** The stable destination host owns presentation. Closing never drops a reconciliation draft. */
    fun close(): Boolean {
        if (mutableState.value.busy) return false
        mutableState.value = mutableState.value.copy(visible = false)
        return true
    }

    fun edit(content: String? = null, note: String? = null, reason: ReportReason? = null) {
        val current = mutableState.value
        if (current.busy) return
        val draft = current.draft ?: return
        val edited = draft.edit(content ?: draft.content, note ?: draft.note, reason ?: draft.reason)
        if (edited == draft) return
        sent = null
        mutableState.value = current.copy(draft = edited, result = null)
    }

    /** Exactly one operation per explicit click. Recomposition/recreation never calls this. */
    fun send(sender: (PreparedReport) -> ReportResult) {
        val current = mutableState.value
        val draft = current.draft ?: return
        if (current.busy || current.result is ReportResult.Received ||
            (current.result as? ReportResult.Rejected)?.code == "conflict") return
        val report = sent ?: ContentReportProtocol.prepare(draft) ?: return
        sent = report
        mutableState.value = current.copy(draft = draft.copy(attempted = true), busy = true)
        viewModelScope.launch {
            val result = try { withContext(ioDispatcher) { sender(report) } }
                catch (cancelled: CancellationException) {
                    mutableState.value = mutableState.value.copy(busy = false, result = ReportResult.Unconfirmed)
                    throw cancelled
                }
                catch (_: Exception) { ReportResult.Unconfirmed }
            mutableState.value = mutableState.value.copy(busy = false, result = result)
        }
    }
}
