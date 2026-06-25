package ai.quenderin.app.ui

import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.FileModelStorage
import ai.quenderin.core.InstalledModel
import ai.quenderin.core.ModelCatalog
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelManager
import ai.quenderin.core.SupportContact
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Settings / manage — twin of iOS `SettingsView`. Shows the active model, on-device storage
 * (conversation count, read fresh from the index), and the in-app About/Privacy. Clearing
 * conversations lives in the chat History sheet, where the live coordinator is.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    model: ModelEntry,
    persistence: ConversationPersistence,
    onSelectModel: (ModelEntry) -> Unit,
) {
    val context = LocalContext.current
    // Read on entry (the tab recomposes fresh each visit); the index file is tiny.
    val conversationCount = remember { persistence.loadIndex().size }
    var showPicker by remember { mutableStateOf(false) }

    // Downloaded-model storage management (twin of iOS SettingsView). The files on disk are the
    // source of truth, so a fresh ModelManager each access reflects the current state.
    val modelsDir = remember { java.io.File(context.filesDir, "models") }
    var installedModels by remember { mutableStateOf(emptyList<InstalledModel>()) }
    var totalModelBytes by remember { mutableStateOf(0L) }
    fun reloadModels() {
        val mgr = ModelManager(FileModelStorage(modelsDir), initialActiveModelId = model.id)
        installedModels = mgr.installed()
        totalModelBytes = mgr.totalBytesUsed
    }
    LaunchedEffect(model.id) { reloadModels() }

    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }) }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionHeader("Model")
            LabeledRow("Active model", model.label)
            LabeledRow("Size", model.sizeLabel)
            OutlinedButton(onClick = { showPicker = true }) { Text("Change model…") }
            Caption("Runs entirely on-device via llama.cpp — no cloud.")

            SectionHeader("Storage")
            LabeledRow("Saved conversations", conversationCount.toString())
            Caption("Browse, switch, or clear conversations from the History button in Chat.")

            SectionHeader("Downloaded models")
            if (installedModels.isEmpty()) {
                Caption("No models downloaded yet.")
            } else {
                installedModels.forEach { installed ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(installed.model.label)
                            if (installed.isActive) {
                                Text(
                                    "Active",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.primary,
                                )
                            }
                        }
                        Text(
                            Formatter.formatShortFileSize(context, installed.sizeBytes),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (!installed.isActive) {
                            TextButton(onClick = {
                                ModelManager(FileModelStorage(modelsDir), initialActiveModelId = model.id)
                                    .delete(installed.id)
                                reloadModels()
                            }) { Text("Delete") }
                        }
                    }
                }
                LabeledRow("Total on device", Formatter.formatShortFileSize(context, totalModelBytes))
            }
            Caption("Delete a model to free space — the active model is protected.")

            SectionHeader("Privacy & support")
            Caption(SupportContact.AI_DISCLAIMER)
            Button(onClick = {
                runCatching {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.PRIVACY_POLICY_URL)))
                }
            }) { Text("Privacy Policy") }
            OutlinedButton(onClick = {
                runCatching {
                    context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${SupportContact.REPORT_EMAIL}")))
                }
            }) { Text("Contact support") }

            Caption(
                "Quenderin runs entirely on your device. No account, no cloud, no tracking — once a " +
                    "model is downloaded it works fully offline, and nothing you type leaves your phone.",
            )
        }
    }

    if (showPicker) {
        ModalBottomSheet(onDismissRequest = { showPicker = false }) {
            ModelPickerSheet(
                currentModelId = model.id,
                onSelect = { picked ->
                    showPicker = false
                    if (picked.id != model.id) onSelectModel(picked)
                },
            )
        }
    }
}

/** Pick a different model: lists the catalog; selecting one downloads it (if needed) and loads it. */
@Composable
private fun ModelPickerSheet(currentModelId: String, onSelect: (ModelEntry) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        Text(
            "Choose a model",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 4.dp),
        )
        Text(
            "Switching downloads the model if it isn't already on your device.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        )
        Column(Modifier.fillMaxWidth().heightIn(max = 480.dp).verticalScroll(rememberScrollState())) {
            ModelCatalog.models.forEach { entry ->
                Row(
                    Modifier.fillMaxWidth().clickable { onSelect(entry) }.padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(entry.label)
                        Text(
                            entry.sizeLabel,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (entry.id == currentModelId) {
                        Text("Current", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun LabeledRow(title: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title)
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
