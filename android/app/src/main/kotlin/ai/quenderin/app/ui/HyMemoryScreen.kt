package ai.quenderin.app.ui

import ai.quenderin.app.HyMemoryController
import ai.quenderin.core.HyMemory
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun HyMemoryScreen(controller: HyMemoryController) {
    val state by controller.state.collectAsState()
    DisposableEffect(controller) { onDispose { controller.cancel() } }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Hy-Memory proposals", style = MaterialTheme.typography.titleMedium)
        Text("A separate local memory writer. Paste only the conversation to review, then approve individual facts before saving.", style = MaterialTheme.typography.bodyMedium)
        Text("Experimental community conversion · Apache-2.0 · 18,236,702,240 bytes · 32 GiB available-memory floor. Model inference is unvalidated. Expert width 768 follows pinned metadata; files are never patched.", style = MaterialTheme.typography.bodySmall)
        controller.blockReason()?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        OutlinedButton(onClick = controller::install, enabled = !state.busy && controller.blockReason() == null) { Text(if (state.installed) "Verify installed specialist" else "Install specialist (18.24 GB)") }
        state.progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
        OutlinedTextField(value = state.conversation, onValueChange = controller::edit, enabled = !state.busy, label = { Text("Selected conversation") }, minLines = 4, modifier = Modifier.fillMaxWidth(), supportingText = { Text("${state.conversation.toByteArray(Charsets.UTF_8).size} / 8,192 UTF-8 bytes. No automatic conversation collection.") })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = controller::propose, enabled = state.installed && !state.busy && controller.runtimeUnavailableReason() == null && state.conversation.isNotBlank() && state.conversation.toByteArray(Charsets.UTF_8).size <= 8192) { Text("Preview proposals") }
            if (state.busy) OutlinedButton(onClick = controller::cancel) { Text("Cancel") }
        }
        state.proposals.forEach { proposal -> Row {
            Checkbox(checked = proposal.id in state.selected, onCheckedChange = { controller.select(proposal.id, it) }, enabled = !state.busy && !proposal.saved)
            Text(proposal.text + if (proposal.saved) " (Saved)" else "", modifier = Modifier.weight(1f))
        } }
        if (state.proposals.isNotEmpty()) Button(onClick = controller::approve, enabled = !state.busy && state.selected.isNotEmpty()) { Text("Save ${state.selected.size} selected memories") }
        Text(state.status, style = MaterialTheme.typography.bodySmall)
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
