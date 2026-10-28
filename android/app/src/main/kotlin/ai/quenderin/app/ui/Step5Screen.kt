package ai.quenderin.app.ui

import ai.quenderin.app.contentreport.ReportSource
import ai.quenderin.app.Step5Controller
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun Step5Screen(controller: Step5Controller) {
    val state by controller.state.collectAsState()
    var confirmClear by remember { mutableStateOf(false) }
    DisposableEffect(controller) { onDispose { controller.cancel() } }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Step 5 CUDA host", style = MaterialTheme.typography.titleMedium)
        Text("Step 5 runs on its official CUDA backend on your chosen host, not the phone's local engine. This conversation is sent to that host only after you confirm below.", style = MaterialTheme.typography.bodyMedium)
        Text("On your host, scripts/run_step5_backend.py starts the pinned backend with already-installed complete FP8 weights and source. It does not download or provision them. Use an SSH tunnel to literal loopback, or an independently secured HTTPS proxy. Credentials are unavailable here; the endpoint stays in memory only.", style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(value = state.endpoint, onValueChange = controller::endpoint, label = { Text("Step 5 gateway origin") }, enabled = !state.busy, singleLine = true, modifier = Modifier.fillMaxWidth(), supportingText = { Text("HTTPS origin or http://127.0.0.1:18000. No credentials, paths, query or fragment.") })
        OutlinedButton(onClick = controller::check, enabled = !state.busy && controller.validEndpoint()) { Text("Check pinned backend") }
        Row { Checkbox(checked = state.consent, onCheckedChange = controller::consent, enabled = !state.busy); Text("I allow this conversation to be sent to the selected CUDA host", modifier = Modifier.weight(1f)) }
        state.messages.forEach { message ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(if (message.role == "user") "You" else "Step 5", style = MaterialTheme.typography.labelMedium)
                if (message.role == "user") Text(message.content)
                else {
                    AssistantResponseText(message.content, MaterialTheme.colorScheme.onSurface)
                    ResponseActions(message.content, ReportSource.STEP5)
                }
            }
        }
        OutlinedTextField(value = state.prompt, onValueChange = controller::prompt, label = { Text("Step 5 prompt") }, enabled = !state.busy, minLines = 3, modifier = Modifier.fillMaxWidth(), supportingText = { Text("${state.prompt.toByteArray(Charsets.UTF_8).size} / 8,192 UTF-8 bytes · ${state.messages.size} stored messages · 32 KiB request limit. History is never silently pruned.") })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = controller::send, enabled = !state.busy && controller.validEndpoint() && state.consent && state.prompt.isNotBlank() && state.prompt.toByteArray(Charsets.UTF_8).size <= 8192) { Text("Send to CUDA host") }
            if (state.busy) OutlinedButton(onClick = controller::cancel) { Text("Cancel") }
        }
        OutlinedButton(onClick = { confirmClear = true }, enabled = !state.busy && state.messages.isNotEmpty()) { Text("Clear conversation…") }
        Text(state.status, style = MaterialTheme.typography.bodySmall)
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, title = { Text("Clear this Step 5 conversation?") }, text = { Text("This clears only the in-memory Step 5 messages. Your host and unsent prompt are kept.") },
        confirmButton = { TextButton(onClick = { controller.clear(); confirmClear = false }) { Text("Clear conversation") } }, dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } })
}
