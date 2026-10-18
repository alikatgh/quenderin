package ai.quenderin.app.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.ContextWrapper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ai.quenderin.app.ImageGenerationController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner

@Composable
fun ImageGenerationScreen(suspendForSpecialist: () -> ai.quenderin.core.SpecialistInferenceLease = { error("The app has not supplied exclusive specialist engine coordination.") }, active: Boolean = true) {
    val context = LocalContext.current
    val controller = remember(context.applicationContext) { ImageGenerationController(context.applicationContext, suspendForSpecialist = suspendForSpecialist) }
    DisposableEffect(controller) { onDispose { controller.close() } }
    LaunchedEffect(active) { if (!active) controller.cancel() }
    val lifecycle = remember(context) { generateSequence(context) { (it as? ContextWrapper)?.baseContext?.takeIf { parent -> parent !== it } }.filterIsInstance<LifecycleOwner>().firstOrNull()?.lifecycle }
    DisposableEffect(controller, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) controller.cancel() }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer); controller.cancel() }
    }
    val state by controller.state.collectAsState()
    var prompt by rememberSaveable { mutableStateOf("") }
    var selectedID by rememberSaveable { mutableStateOf("moss-image-sft") }
    var selecting by remember { mutableStateOf(false) }
    var pendingExport by remember { mutableStateOf<File?>(null) }
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    LaunchedEffect(controller) { controller.select(selectedID); controller.setPrompt(prompt) }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { files ->
        if (files.isNotEmpty()) controller.install(files)
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) { uri ->
        val image = pendingExport
        pendingExport = null
        if (uri != null && image != null) scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val output = context.contentResolver.openOutputStream(uri, "w") ?: error("Could not open image destination")
                    output.use { target -> image.inputStream().use { it.copyTo(target) } }
                }
                controller.reportSaved()
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { controller.reportError(error.message ?: "The image could not be saved.") }
        }
    }
    val bitmap by produceState<Bitmap?>(null, state.output?.absolutePath) {
        value = withContext(Dispatchers.IO) { state.output?.let { BitmapFactory.decodeFile(it.absolutePath) } }
    }
    val model = state.selected
    val available = controller.engine.available
    val fitReason = controller.fitReason(installing = !state.installed)
    val canInstall = !state.busy && available && controller.fitReason(installing = true) == null

    LazyColumn(Modifier.fillMaxSize().imePadding(), contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { Text("Images", style = MaterialTheme.typography.headlineMedium) }
        item {
            Box {
                OutlinedButton(onClick = { selecting = true }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(model?.label ?: "Choose image model")
                }
                DropdownMenu(expanded = selecting, onDismissRequest = { selecting = false }) {
                    state.models.forEach { entry ->
                        DropdownMenuItem(text = { Text(entry.label) }, onClick = {
                            selectedID = entry.id; controller.select(entry.id); selecting = false
                        })
                    }
                }
            }
        }
        if (model != null) {
            item {
                Text("${String.format(Locale.ROOT, "%.2f", model.downloadBytes / 1_000_000_000.0)} GB · ${model.components.size} required components · 512 × 512",
                    style = MaterialTheme.typography.bodyMedium)
                Text("Experimental local image generation. Allow at least 24 GiB of available app memory. Full-weight inference and performance remain unverified.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (!available) item { Text("This build does not include the local image engine.") }
            if (fitReason != null) item { Text(fitReason, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            item { TextButton(onClick = { uriHandler.openUri(model.licenseUrl) }) { Text("Publisher terms: ${model.license}") } }
            if (model.requiresPublisherAccess) {
                item {
                    Text("Get access from the publisher, then import the original model, text encoder and VAE files. Quenderin does not download gated files for you.",
                        style = MaterialTheme.typography.bodySmall)
                    Row {
                        Checkbox(checked = state.publisherTermsAccepted, onCheckedChange = controller::acceptPublisherTerms, enabled = !state.busy)
                        Text("I have reviewed and accepted the publisher terms", modifier = Modifier.weight(1f))
                    }
                }
            }
            item {
                if (state.installed) Text("All components present; checksums are verified before generation.")
                else Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!model.requiresPublisherAccess) Button(onClick = { controller.install() }, enabled = canInstall) {
                        Text("Download ${String.format(Locale.ROOT, "%.2f", model.downloadBytes / 1_000_000_000.0)} GB")
                    }
                    OutlinedButton(onClick = { importer.launch(arrayOf("*/*")) },
                        enabled = canInstall && (!model.requiresPublisherAccess || state.publisherTermsAccepted)) {
                        Text("Import model components…")
                    }
                }
            }
        }
        item { HorizontalDivider() }
        item {
            OutlinedTextField(value = prompt, onValueChange = { prompt = it; controller.setPrompt(it) },
                modifier = Modifier.fillMaxWidth(), enabled = !state.busy, label = { Text("Image description") }, minLines = 4, maxLines = 8)
        }
        if (model?.modelKind == 1) item {
            Text("FLUX works from a complete scene caption. Include the subject, setting, lighting and composition. Reference-image input is not available in this screen.",
                style = MaterialTheme.typography.bodySmall)
        }
        item {
            Button(onClick = controller::generate, enabled = !state.busy && state.installed && available && prompt.isNotBlank() &&
                (model?.requiresPublisherAccess != true || state.publisherTermsAccepted)) {
                Text("Generate one image")
            }
        }
        if (state.busy) item {
            val progress = state.progress
            if (progress == null) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            else LinearProgressIndicator(progress = progress, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = controller::cancel) { Text("Cancel") }
        }
        item {
            Text(state.status, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        bitmap?.let { image -> if (state.output != null) item {
            Image(bitmap = image.asImageBitmap(), contentDescription = "Generated image", modifier = Modifier.fillMaxWidth().heightIn(max = 512.dp))
            Button(onClick = { pendingExport = state.output; exporter.launch("Quenderin-image.png") }) { Text("Save image…") }
        } }
    }
}
