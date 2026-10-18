package ai.quenderin.app.ui

import android.content.ContextWrapper
import ai.quenderin.app.VisionController
import ai.quenderin.core.VisionModels
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner

@Composable fun VisionScreen(controller: VisionController) {
    val state by controller.state.collectAsState()
    val context = LocalContext.current
    var components by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) controller.chooseImage(uri) }
    val lifecycle = remember(context) { generateSequence(context) { (it as? ContextWrapper)?.baseContext?.takeIf { parent -> parent !== it } }.filterIsInstance<LifecycleOwner>().firstOrNull()?.lifecycle }
    DisposableEffect(controller, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) controller.cancel() }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer); controller.cancel() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Ask about one still image", style = MaterialTheme.typography.titleMedium)
        Text("Separate from your answer model. PNG or JPEG only; video and tools are unavailable. Experimental source integration: model inference has not been validated.", style = MaterialTheme.typography.bodyMedium)
        Text("Vision model", style = MaterialTheme.typography.labelLarge)
        VisionModels.all.forEach { model -> OutlinedButton(onClick = { controller.select(model.id) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text(if (state.selectedID == model.id) "Selected: ${model.label}" else model.label) } }
        Text("${state.model.minimumMemoryBytes / 1_073_741_824} GiB available app memory required, including projector and context. Large models are never selected automatically.", style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { components = !components }) { Text("${if (components) "Hide" else "Show"} both required components · ${state.model.artifacts.sumOf { it.bytes }} bytes") }
        if (components) state.model.artifacts.forEach { part -> Column { Text(part.filename, style = MaterialTheme.typography.bodySmall); Text("${part.bytes} bytes · SHA-256 ${part.sha256}", style = MaterialTheme.typography.labelSmall); Text(part.url, style = MaterialTheme.typography.labelSmall) } }
        controller.blockReason()?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        OutlinedButton(onClick = controller::install, enabled = !state.busy && controller.blockReason() == null) { Text(if (state.installed) "Verify complete installation" else "Install complete model and projector") }
        state.progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
        OutlinedButton(onClick = { picker.launch(arrayOf("image/png", "image/jpeg")) }, enabled = !state.busy) { Text("Choose PNG or JPEG…") }
        Text(state.imageLabel, style = MaterialTheme.typography.bodySmall)
        Text("Up to 8 MiB, 4,096 pixels per side and 16 million pixels. Only your chosen image is copied into private app storage.", style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(value = state.prompt, onValueChange = controller::prompt, label = { Text("Question about the selected still image") }, enabled = !state.busy, minLines = 3, modifier = Modifier.fillMaxWidth(), supportingText = { Text("${state.prompt.toByteArray(Charsets.UTF_8).size} / 8,192 UTF-8 bytes · 512 output tokens · 4,096-token context") })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = controller::ask, enabled = !state.busy && state.installed && state.image != null && state.prompt.isNotBlank() && state.prompt.toByteArray(Charsets.UTF_8).size <= 8192 && controller.runtimeAvailable()) { Text("Ask about image") }
            if (state.busy) OutlinedButton(onClick = controller::cancel) { Text("Cancel") }
        }
        Text(state.status, style = MaterialTheme.typography.bodySmall)
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (state.answer.isNotEmpty()) Text(state.answer)
    }
}
