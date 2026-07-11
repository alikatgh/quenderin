package ai.quenderin.app.ui

import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R

import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.FileModelStorage
import ai.quenderin.core.InstalledModel
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelManager
import ai.quenderin.core.SpeedPreset
import ai.quenderin.core.SpeedPresets
import ai.quenderin.core.SupportContact
import androidx.compose.foundation.clickable
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    deepThinking: Boolean = false,
    onDeepThinkingChange: (Boolean) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
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

    // No nested Scaffold/TopAppBar here: this screen already sits inside MainTabs' Scaffold content
    // (which applies the status-bar inset once). A second Scaffold+TopAppBar re-applied that inset,
    // producing the big empty band above the title. A plain titled column avoids the double inset.
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            "Settings",
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.padding(top = 16.dp, bottom = 4.dp),
        )
        SettingsGroup("Speed") {
            // The model-speed dial: decode speed scales with model SIZE, so this is the one control
            // that changes how fast replies FEEL. Selecting a preset runs the normal switch flow
            // (download if needed → load → swap).
            val totalRamGb = remember {
                val am = context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                val mi = android.app.ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
                mi.totalMem / 1_073_741_824.0
            }
            val choice = remember(totalRamGb) { SpeedPresets.forDevice(totalRamGb) }
            val current = choice.presetFor(model.id)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PresetChip("Fast", current == SpeedPreset.FAST, Modifier.weight(1f)) {
                    if (choice.fast.id != model.id) onSelectModel(choice.fast)
                }
                PresetChip("Balanced", current == SpeedPreset.BALANCED, Modifier.weight(1f)) {
                    if (choice.balanced.id != model.id) onSelectModel(choice.balanced)
                }
                PresetChip("Quality", current == SpeedPreset.QUALITY, Modifier.weight(1f)) {
                    if (choice.quality.id != model.id) onSelectModel(choice.quality)
                }
            }
            Caption(
                if (current == null) "Custom model active (${model.label}) — pick a preset to switch."
                else "Fast: ${choice.fast.label} · Balanced: ${choice.balanced.label} · Quality: ${choice.quality.label}. " +
                    "Switching downloads the model if needed.",
            )
        }

        SettingsGroup("Model") {
            LabeledRow("Active model", model.label)
            LabeledRow("Size", model.sizeLabel)
            OutlinedButton(onClick = { showPicker = true }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.model_change))
            }
            Caption("Runs entirely on-device via llama.cpp — no cloud.")
        }

        SettingsGroup("Reasoning") {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.model_deep_thinking), color = MaterialTheme.colorScheme.onSurface)
                    Caption(
                        if (deepThinking) "The model reasons step-by-step before answering — better on hard " +
                            "questions, but noticeably slower."
                        else "Off: fast, direct answers. Turn on to let the model reason step-by-step (slower).",
                    )
                }
                Switch(checked = deepThinking, onCheckedChange = onDeepThinkingChange)
            }
        }

        // The agent capability pane — the Android twin of the iOS Settings → Agent section and the
        // dashboard's "What it can do here": every T1+ capability in plain words with its consent
        // toggle (the SAME PrefsConsentStore the Agent screen's runner reads, so this pane IS the
        // grant), plus the last ledger rows — refusals included, the local flight recorder.
        SettingsGroup("Agent") {
            val consent = remember { ai.quenderin.app.PrefsConsentStore(context) }
            // Metadata-only instances (empty seams) — listing runs nothing; the pane can't drift
            // from the agent because both read the same capability classes and consent store.
            val gated = remember {
                listOf(ai.quenderin.core.FileReadCapability(grantedFiles = { emptyMap() })) +
                    ai.quenderin.app.docWorkspaceCapabilities({ null }, ai.quenderin.app.DocUndoJournal()) +
                    ai.quenderin.app.devicePerceptionCapabilities(context)
            }
            Caption("Calculator, unit and date tools are always on — pure compute, no side effects.")
            // Opt-in "Deeper reasoning" for the AGENT (distinct from chat's Deep thinking) — the twin of
            // the iOS Settings → Agent "Deeper reasoning" toggle. Writes the SAME "agent.deliberation"
            // key the Agent screen reads live at run time. Self-contained (local state + direct prefs
            // write) like the consent switches below.
            run {
                val agentPrefs = remember { context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE) }
                var deliberation by remember { mutableStateOf(agentPrefs.getBoolean("agent.deliberation", false)) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.settings_deeper_reasoning), color = MaterialTheme.colorScheme.onSurface)
                        Caption("Let the agent think through each step before it acts — better tool choice on " +
                            "tricky goals, but slower. Off by default; applies to your next run.")
                    }
                    Switch(
                        checked = deliberation,
                        onCheckedChange = { on ->
                            deliberation = on
                            agentPrefs.edit().putBoolean("agent.deliberation", on).apply()
                        },
                    )
                }
            }
            gated.forEach { cap ->
                var granted by remember { mutableStateOf(consent.isGranted(cap.name)) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(cap.name, color = MaterialTheme.colorScheme.onSurface)
                        Caption(cap.purpose)
                    }
                    Switch(
                        checked = granted,
                        onCheckedChange = { g ->
                            granted = g
                            consent.setGranted(cap.name, g)
                        },
                    )
                }
            }
            val ledgerRows = remember {
                ai.quenderin.core.FileAuditLedger(java.io.File(context.filesDir, "agent-ledger.jsonl"))
                    .entries().takeLast(10).reversed()
            }
            if (ledgerRows.isNotEmpty()) {
                Caption("Recent agent activity (newest first, refusals included):")
                ledgerRows.forEach { row ->
                    Text(
                        "${if (row.decision == "allowed") "✓" else "✗"} ${row.capability} · ${row.decision}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            // Privacy affordance: clear skill memory (what the agent learned from past runs).
            run {
                val skillStore = remember { ai.quenderin.app.PrefsSkillMemoryStore(context) }
                var skillCount by remember { mutableStateOf(skillStore.memory().size) }
                if (skillCount > 0) {
                    Caption("Remembered skills from past agent runs: $skillCount (local only).")
                    TextButton(onClick = {
                        skillStore.clear()
                        skillCount = 0
                    }) {
                        Text(stringResource(R.string.settings_clear_skills))
                    }
                } else {
                    Caption("No learned agent skills stored yet.")
                }
            }
        }

            SettingsGroup("Storage") {
                LabeledRow("Saved conversations", conversationCount.toString())
                Caption("Browse, switch, or clear conversations from the History button in Chat.")
            }

            SettingsGroup("Downloaded models") {
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
                                TextButton(
                                    onClick = {
                                        // Deleting a model unlinks a multi-GB GGUF — blocking FS I/O that
                                        // froze the UI / risked an ANR when run directly in the click lambda
                                        // (main thread). Do the unlink on Dispatchers.IO, then refresh state
                                        // back on the caller (Main) so the list write stays on the UI thread.
                                        scope.launch {
                                            withContext(Dispatchers.IO) {
                                                ModelManager(FileModelStorage(modelsDir), initialActiveModelId = model.id)
                                                    .delete(installed.id)
                                            }
                                            reloadModels()
                                        }
                                    },
                                    modifier = Modifier.semantics { contentDescription = "Delete ${installed.model.label}" },
                                ) { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) }
                            }
                        }
                    }
                    LabeledRow("Total on device", Formatter.formatShortFileSize(context, totalModelBytes))
                }
                Caption("Delete a model to free space — the active model is protected.")
            }

            SettingsGroup("Privacy & support") {
                Caption(SupportContact.AI_DISCLAIMER)
                Button(
                    onClick = {
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.PRIVACY_POLICY_URL)))
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.settings_privacy_policy)) }
                OutlinedButton(
                    onClick = {
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${SupportContact.REPORT_EMAIL}")))
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.settings_contact_support)) }
                // Open source is a feature — say so where users look for "who made this".
                OutlinedButton(
                    onClick = {
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.GITHUB_URL)))
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.settings_open_source_github)) }
            }

        Caption(
            "Quenderin runs entirely on your device. No account, no cloud, no tracking — once a " +
                "model is downloaded it works fully offline, and nothing you type leaves your phone.",
        )
        Spacer(Modifier.height(24.dp))   // breathing room at the very bottom, above the nav bar
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

/**
 * One segment of the speed dial: a pill that reads selected through COLOR only (brand-tinted fill +
 * hairline) — geometry identical in both states, per the design rules.
 */
@Composable
private fun PresetChip(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface,
        shape = QuenderinShapes.pill,
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = modifier,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier
                .clickable(onClick = onClick)
                .padding(vertical = 10.dp)
                .fillMaxWidth(),
        )
    }
}

/** A titled settings section: a small primary-tinted label above a rounded surface card holding the rows. */
@Composable
private fun SettingsGroup(title: String, content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 4.dp, bottom = 8.dp),
        )
        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = QuenderinShapes.card,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                content = content,
            )
        }
    }
}

@Composable
private fun LabeledRow(title: String, value: String) {
    Row(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(title)
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
