package ai.quenderin.app.ui

import ai.quenderin.app.R
import ai.quenderin.app.contentreport.ContentReportProtocol
import ai.quenderin.app.contentreport.ContentReportTransport
import ai.quenderin.app.contentreport.ContentReportViewModel
import ai.quenderin.app.contentreport.ReportReason
import ai.quenderin.app.contentreport.ReportResult
import ai.quenderin.app.contentreport.PreparedReport
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.semantics.Role
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy

private object ReportSender {
    val transport by lazy { ContentReportTransport() }
}

/** Tests can provide a synthetic receipt here; the production sender has no synthetic fallback. */
val LocalContentReportSender = staticCompositionLocalOf<(PreparedReport) -> ReportResult> {
    { report -> ReportSender.transport.send(report) }
}

/** Mount exactly once in AppRoot, before any conditional route or first-run return.
 * Production reports always use SecureOn, including after leaving a protected cloud destination.
 * Only synthetic test compositions pass SecureOff to allow their selected screenshot evidence. */
@Composable
fun ContentReportHost(model: ContentReportViewModel = viewModel(), securePolicy: SecureFlagPolicy = SecureFlagPolicy.SecureOn) {
    val state by model.state.collectAsStateWithLifecycle()
    if (!state.visible) return
    val selectionId = state.selectionId ?: return
    // Root can restore a full-screen cloud Dialog later in this same composition. Attach the
    // report window after its first frame so the restored route cannot cover the report window.
    var attached by remember(selectionId) { mutableStateOf(false) }
    LaunchedEffect(selectionId) { withFrameNanos { }; attached = true }
    if (attached) ContentReportDialog(model, selectionId, onClose = { model.close() }, securePolicy = securePolicy)
}

/** No send is performed by composition. The supplied single-message preview is editable and all
 * sending is an explicit action. Failure keeps the exact draft/ID for manual reconciliation. */
@Composable
fun ContentReportDialog(
    model: ContentReportViewModel,
    selectionId: String,
    onClose: () -> Unit,
    sendReport: ((PreparedReport) -> ReportResult)? = null,
    securePolicy: SecureFlagPolicy = SecureFlagPolicy.SecureOn,
) {
    val state by model.state.collectAsStateWithLifecycle()
    if (!state.visible || state.selectionId != selectionId) return
    val draft = state.draft ?: return // Process death restores no payload and triggers no replay.
    val busy = state.busy
    val result = state.result
    val sender = sendReport ?: LocalContentReportSender.current
    val ready = ContentReportProtocol.prepare(draft)
    val received = result as? ReportResult.Received
    var excerptEditRejected by remember(selectionId) { mutableStateOf(false) }
    var noteEditRejected by remember(selectionId) { mutableStateOf(false) }
    val excerptTooLong = excerptEditRejected || draft.content.toByteArray(Charsets.UTF_8).size > ContentReportProtocol.CONTENT_BYTES
    val noteTooLong = noteEditRejected || draft.note.toByteArray(Charsets.UTF_8).size > ContentReportProtocol.NOTE_BYTES
    val inputTooLong = excerptTooLong || noteTooLong
    val status = when (val current = result) {
        ReportResult.Unavailable -> R.string.report_unavailable
        ReportResult.Unconfirmed -> R.string.report_unconfirmed
        is ReportResult.Rejected -> when (current.code) {
            "too_large" -> R.string.report_too_large
            "invalid_request" -> R.string.report_invalid
            "conflict" -> R.string.report_conflict
            else -> R.string.report_unconfirmed
        }
        else -> if (ready == null && !inputTooLong && draft.content.isNotBlank()) {
            R.string.report_invalid
        } else null
    }
    AlertDialog(
        properties = DialogProperties(securePolicy = securePolicy),
        modifier = Modifier.testTag("contentReport.dialog"),
        onDismissRequest = { if (!busy) onClose() },
        title = { Text(stringResource(if (received != null) R.string.report_received else R.string.report_title)) },
        text = {
            Column(Modifier.heightIn(max = 520.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (received != null) {
                        Text(stringResource(R.string.report_receipt, received.receiptId),
                            modifier = Modifier.testTag("contentReport.status").semantics { liveRegion = LiveRegionMode.Polite })
                    } else {
                        Text(stringResource(R.string.report_intro), style = MaterialTheme.typography.bodyMedium)
                        if (state.truncated) Text(stringResource(R.string.report_excerpt_truncated), style = MaterialTheme.typography.bodySmall)
                        OutlinedTextField(value = draft.content, onValueChange = {
                            // A UI code-unit cap bounds editing before byte validation, without trimming user text.
                            excerptEditRejected = it.length > ContentReportProtocol.CONTENT_BYTES
                            if (it.length <= ContentReportProtocol.CONTENT_BYTES) {
                                model.edit(content = it)
                            }
                        }, enabled = !busy, modifier = Modifier.fillMaxWidth().testTag("contentReport.excerpt"),
                            label = { Text(stringResource(R.string.report_excerpt)) }, minLines = 3, maxLines = 7,
                            isError = excerptTooLong,
                            supportingText = if (excerptTooLong) {
                                { Text(stringResource(R.string.report_excerpt_too_long)) }
                            } else null)
                        Text(stringResource(R.string.report_excerpt_help), style = MaterialTheme.typography.bodySmall)
                        Text(stringResource(R.string.report_reason), style = MaterialTheme.typography.labelLarge)
                        ReportReason.entries.forEach { reason ->
                            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                                .selectable(selected = draft.reason == reason, enabled = !busy, role = Role.RadioButton,
                                    onClick = { model.edit(reason = reason) })
                                .testTag("contentReport.reason.${reason.wire}"), verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = draft.reason == reason, onClick = null, enabled = !busy)
                                Text(stringResource(reason.label()))
                            }
                        }
                        OutlinedTextField(value = draft.note, onValueChange = {
                            noteEditRejected = it.length > ContentReportProtocol.NOTE_BYTES
                            if (it.length <= ContentReportProtocol.NOTE_BYTES) model.edit(note = it)
                        }, enabled = !busy, modifier = Modifier.fillMaxWidth().testTag("contentReport.note"),
                            label = { Text(stringResource(R.string.report_note)) }, minLines = 2, maxLines = 4,
                            isError = noteTooLong,
                            supportingText = if (noteTooLong) {
                                { Text(stringResource(R.string.report_note_too_long)) }
                            } else null)
                    }
                }
                status?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("contentReport.status").semantics { liveRegion = LiveRegionMode.Polite }) }
            }
        },
        confirmButton = {
            if (received == null) TextButton(onClick = {
                model.send(sender)
            }, enabled = !busy && ready != null && !inputTooLong && (result as? ReportResult.Rejected)?.code != "conflict",
                modifier = Modifier.heightIn(min = 48.dp).testTag(if (draft.attempted) "contentReport.retry" else "contentReport.send")) {
                Text(stringResource(when { busy -> R.string.report_sending; draft.attempted -> R.string.report_retry; else -> R.string.report_send }))
            }
        },
        dismissButton = {
            TextButton(onClick = onClose, enabled = !busy, modifier = Modifier.heightIn(min = 48.dp).testTag("contentReport.close")) {
                Text(stringResource(R.string.report_close))
            }
        },
    )
}

private fun ReportReason.label(): Int = when (this) {
    ReportReason.HARASSMENT -> R.string.report_reason_harassment
    ReportReason.HATE -> R.string.report_reason_hate
    ReportReason.SEXUAL -> R.string.report_reason_sexual
    ReportReason.VIOLENCE -> R.string.report_reason_violence
    ReportReason.DANGEROUS -> R.string.report_reason_dangerous
    ReportReason.OTHER -> R.string.report_reason_other
}
