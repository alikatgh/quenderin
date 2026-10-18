package ai.quenderin.app.ui

import ai.quenderin.app.GraniteController
import ai.quenderin.core.GraniteMessage
import android.content.ContextWrapper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner

@Composable fun GraniteScreen(controller: GraniteController) {
    val state by controller.state.collectAsState()
    val context = LocalContext.current
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> if (uris.isNotEmpty()) controller.importPair(uris) }
    val lifecycle = remember(context) { generateSequence(context) { (it as? ContextWrapper)?.baseContext?.takeIf { parent -> parent !== it } }.filterIsInstance<LifecycleOwner>().firstOrNull()?.lifecycle }
    DisposableEffect(controller, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) controller.cancel() }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer); controller.cancel() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Granite Switch 4.1 8B", style = MaterialTheme.typography.titleMedium)
        Text("Local converted GGUF · text chat only · at least 32 GiB available app memory", style = MaterialTheme.typography.bodySmall)
        Text("Choose the GGUF produced by scripts/convert_granite41.py together with its .quenderin.json record. Speech, guardian decisions and tools are unavailable.", style = MaterialTheme.typography.bodySmall)
        controller.blockReason()?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        OutlinedButton(onClick = { picker.launch(arrayOf("*/*")) }, enabled = !state.busy && controller.blockReason() == null) { Text(if (state.model == null) "Import GGUF and record…" else "Choose another conversion…") }
        state.model?.let { Text("Local model selected. Verified imports of the same conversion are reused.", style = MaterialTheme.typography.bodySmall) }
        state.progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
        state.messages.forEach { message -> Column {
            Text(if (message.role == GraniteMessage.Role.USER) "You" else "Granite", style = MaterialTheme.typography.labelLarge)
            SelectionContainer { Text(message.content) }
        } }
        OutlinedTextField(value = state.prompt, onValueChange = controller::prompt, label = { Text("Question for Granite") }, enabled = !state.busy,
            minLines = 3, modifier = Modifier.fillMaxWidth(), supportingText = { Text("${state.prompt.toByteArray(Charsets.UTF_8).size} / 8,192 UTF-8 bytes · 512 output tokens · 4,096-token context") })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = controller::ask, enabled = !state.busy && state.model != null && state.prompt.isNotBlank() && controller.blockReason() == null) { Text("Ask Granite") }
            if (state.busy) OutlinedButton(onClick = controller::cancel) { Text("Cancel") }
        }
        TextButton(onClick = controller::newConversation, enabled = !state.busy && state.messages.isNotEmpty()) { Text("New conversation") }
        Text(state.status, style = MaterialTheme.typography.bodySmall)
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
