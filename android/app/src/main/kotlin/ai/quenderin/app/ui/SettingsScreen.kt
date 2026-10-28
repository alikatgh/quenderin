package ai.quenderin.app.ui

import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R
import ai.quenderin.app.probeDeviceProfile
import ai.quenderin.core.AndroidModelSelector
import ai.quenderin.app.HyMemoryController
import ai.quenderin.app.Step5Controller
import ai.quenderin.app.VisionController
import ai.quenderin.app.GraniteController
import ai.quenderin.core.HyMemoryNativeInferencePort

import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.FileModelStorage
import ai.quenderin.core.InstalledModel
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelManager
import ai.quenderin.core.SpeedPreset
import ai.quenderin.core.SpeedPresets
import ai.quenderin.core.SupportContact
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
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
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
    onOpenDeepSeek: () -> Unit = {},
    onOpenComputer: () -> Unit = {},
    deepThinking: Boolean = false,
    onDeepThinkingChange: (Boolean) -> Unit = {},
    active: Boolean = true,
    automaticEnabled: Boolean = false,
    onAutomaticChange: (Boolean) -> Unit = {},
    automaticDescription: () -> String = { "Estimated speed · current local model" },
    suspendForSpecialist: () -> ai.quenderin.core.SpecialistInferenceLease = { error("The app has not supplied exclusive specialist engine coordination.") },
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val hyMemory = remember { HyMemoryController(context, HyMemoryNativeInferencePort(context.applicationInfo.nativeLibraryDir) { HyMemoryController.availableMemoryBytes(context) }, suspendForSpecialist) }
    val step5 = remember { Step5Controller() }
    val vision = remember { VisionController(context, suspendForSpecialist) }
    val granite = remember { GraniteController(context, suspendForSpecialist) }
    androidx.compose.runtime.DisposableEffect(granite) { onDispose { granite.close() } }
    androidx.compose.runtime.DisposableEffect(vision) { onDispose { vision.close() } }
    // Read on entry (the tab recomposes fresh each visit); the index file is tiny.
    val conversationCount = remember(active) { persistence.loadIndex().size }
    var showPicker by remember { mutableStateOf(false) }
    var page by rememberSaveable { mutableStateOf(SettingsPage.ROOT) }
    val pageState = rememberSaveableStateHolder()
    BackHandler(enabled = active && page != SettingsPage.ROOT && !showPicker) { page = SettingsPage.ROOT }
    LaunchedEffect(active, page) {
        if (!active || page != SettingsPage.MEMORY) hyMemory.cancel()
        if (!active || page != SettingsPage.STEP5) step5.cancel()
        if (!active || page != SettingsPage.VISION) vision.cancel()
        if (!active || page != SettingsPage.GRANITE) granite.cancel()
    }

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
    LaunchedEffect(model.id, active, page) { if (active) reloadModels() }

    // MainTabs owns system-bar insets; each subordinate page owns only its scrolling content.
    pageState.SaveableStateProvider(page.name) {
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .testTag(if (page == SettingsPage.ROOT) "settings.root" else "settings.detail"),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (page != SettingsPage.ROOT) {
            TextButton(onClick = { page = SettingsPage.ROOT }, modifier = Modifier.testTag("settings.back")) {
                Text(stringResource(R.string.action_back))
            }
        }
        Text(
            settingsPageTitle(page),
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
        )
        if (page == SettingsPage.ROOT) {
            Text(model.label, style = MaterialTheme.typography.bodyLarge)
            Caption(stringResource(R.string.entry_local_ready, model.sizeLabel.removeSuffix(" download")))
            NativeSectionLabel(stringResource(R.string.entry_local_title))
            NativeSettingsRow(stringResource(R.string.settings_model), model.label,
                { page = SettingsPage.MODELS }, Modifier.testTag("settings.models"))
            NativeSettingsRow(stringResource(R.string.settings_responses), stringResource(R.string.settings_responses_detail),
                { page = SettingsPage.RESPONSES }, Modifier.testTag("settings.responses"))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            NativeSectionLabel(stringResource(R.string.settings_connections))
            NativeSettingsRow(stringResource(R.string.entry_deepseek_title), stringResource(R.string.entry_deepseek_detail),
                onOpenDeepSeek, Modifier.testTag("settings.deepseek"))
            NativeSettingsRow(stringResource(R.string.entry_computer_title), stringResource(R.string.entry_computer_detail),
                onOpenComputer, Modifier.testTag("settings.computer"))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            NativeSectionLabel(stringResource(R.string.settings_tools))
            NativeSettingsRow(stringResource(R.string.settings_agent), stringResource(R.string.settings_agent_detail),
                { page = SettingsPage.AGENT }, Modifier.testTag("settings.agent"))
            NativeSettingsRow(stringResource(R.string.settings_memory), stringResource(R.string.settings_memory_detail),
                { page = SettingsPage.MEMORY }, Modifier.testTag("settings.memory"))
            NativeSettingsRow(stringResource(R.string.settings_vision), stringResource(R.string.settings_vision_detail),
                { page = SettingsPage.VISION }, Modifier.testTag("settings.vision"))
            NativeSettingsRow(stringResource(R.string.settings_step5), stringResource(R.string.settings_step5_detail),
                { page = SettingsPage.STEP5 }, Modifier.testTag("settings.step5"))
            NativeSettingsRow("Granite Switch 4.1 8B", stringResource(R.string.settings_granite_detail),
                { page = SettingsPage.GRANITE }, Modifier.testTag("settings.granite"))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            NativeSectionLabel(stringResource(R.string.settings_app))
            NativeSettingsRow(stringResource(R.string.settings_storage), stringResource(R.string.settings_storage_detail),
                { page = SettingsPage.STORAGE }, Modifier.testTag("settings.storage"))
            NativeSettingsRow(stringResource(R.string.settings_privacy_support), stringResource(R.string.settings_privacy_detail),
                { page = SettingsPage.PRIVACY }, Modifier.testTag("settings.privacy"))
        }
        if (page == SettingsPage.RESPONSES) SettingsGroup(stringResource(R.string.settings_speed)) {
            PresetChip(stringResource(R.string.settings_automatic), automaticEnabled, Modifier.fillMaxWidth()) { onAutomaticChange(!automaticEnabled) }
            Caption(stringResource(R.string.settings_automatic_detail))
            if (automaticEnabled) Caption(automaticDescription())
            // The model-speed dial: decode speed scales with model SIZE, so this is the one control
            // that changes how fast replies FEEL. Selecting a preset runs the normal switch flow
            // (download if needed → load → swap).
            // Quality = the SAME pick onboarding made (native-heap-budget selector over the shared
            // device probe), not a total-RAM band — the twin of the iOS Settings dial.
            val profile = remember { context.probeDeviceProfile() }
            val choice = remember(profile) {
                SpeedPresets.forDevice(profile.totalRamGb, quality = AndroidModelSelector.select(profile).model)
            }
            val current = choice.presetFor(model.id)
            val fastLabel = stringResource(R.string.settings_speed_fast)
            val balLabel = stringResource(R.string.settings_speed_balanced)
            val qualLabel = stringResource(R.string.settings_speed_quality)
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                PresetChip(fastLabel, !automaticEnabled && current == SpeedPreset.FAST, Modifier.fillMaxWidth()) {
                    onSelectModel(choice.fast)
                }
                PresetChip(balLabel, !automaticEnabled && current == SpeedPreset.BALANCED, Modifier.fillMaxWidth()) {
                    onSelectModel(choice.balanced)
                }
                PresetChip(qualLabel, !automaticEnabled && current == SpeedPreset.QUALITY, Modifier.fillMaxWidth()) {
                    onSelectModel(choice.quality)
                }
            }
            Caption(
                if (current == null) {
                    stringResource(R.string.settings_custom_model, model.label)
                } else {
                    stringResource(
                        R.string.settings_speed_presets_line,
                        choice.fast.label,
                        choice.balanced.label,
                        choice.quality.label,
                    )
                },
            )
        }

        if (page == SettingsPage.MODELS) SettingsGroup(stringResource(R.string.settings_model), showHeading = false) {
            LabeledRow(stringResource(R.string.settings_active_model), model.label)
            LabeledRow(stringResource(R.string.settings_size), model.sizeLabel)
            val engineStatus = if (ai.quenderin.core.LlamaEngine.NATIVE_AVAILABLE) {
                stringResource(R.string.settings_engine_real)
            } else {
                stringResource(R.string.settings_engine_demo)
            }
            LabeledRow(stringResource(R.string.settings_engine), engineStatus)
            if (!ai.quenderin.core.LlamaEngine.NATIVE_AVAILABLE) {
                Caption(stringResource(R.string.settings_engine_demo_hint))
            }
            OutlinedButton(onClick = { showPicker = true }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.model_change))
            }
            Caption(stringResource(R.string.settings_on_device_llama))
        }

        if (page == SettingsPage.RESPONSES) SettingsGroup(stringResource(R.string.settings_reasoning)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .toggleable(value = deepThinking, role = Role.Switch, onValueChange = onDeepThinkingChange),
                verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.model_deep_thinking), color = MaterialTheme.colorScheme.onSurface)
                    Caption(
                        if (deepThinking) stringResource(R.string.settings_deep_thinking_on)
                        else stringResource(R.string.settings_deep_thinking_off),
                    )
                }
                Switch(checked = deepThinking, onCheckedChange = null)
            }
        }

        // Twin of iOS Settings → Routing (AppSettings.suggestBestModel). ChatScreen reads the same key.
        if (page == SettingsPage.RESPONSES) SettingsGroup(stringResource(R.string.settings_routing)) {
            val routePrefs = remember {
                context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
            }
            var suggestBest by remember {
                mutableStateOf(routePrefs.getBoolean("suggestBestModel", true))
            }
            fun updateSuggestion(on: Boolean) {
                suggestBest = on
                routePrefs.edit().putBoolean("suggestBestModel", on).apply()
            }
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .toggleable(value = suggestBest, role = Role.Switch, onValueChange = ::updateSuggestion),
                verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.settings_suggest_best_model),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Caption(stringResource(R.string.settings_suggest_best_model_hint))
                }
                Switch(
                    checked = suggestBest,
                    onCheckedChange = null,
                )
            }
        }

        // The agent capability pane — the Android twin of the iOS Settings → Agent section and the
        // dashboard's "What it can do here": every T1+ capability in plain words with its consent
        // toggle (the SAME PrefsConsentStore the Agent screen's runner reads, so this pane IS the
        // grant), plus the last ledger rows — refusals included, the local flight recorder.
        if (page == SettingsPage.MEMORY) HyMemoryScreen(hyMemory)
        if (page == SettingsPage.STEP5) Step5Screen(step5)
        if (page == SettingsPage.VISION) VisionScreen(vision)
        if (page == SettingsPage.GRANITE) GraniteScreen(granite)
        if (page == SettingsPage.AGENT) SettingsGroup(stringResource(R.string.settings_agent), showHeading = false) {
            val consent = remember { ai.quenderin.app.PrefsConsentStore(context) }
            // Metadata-only instances (empty seams) — listing runs nothing; the pane can't drift
            // from the agent because both read the same capability classes and consent store.
            val gated = remember {
                listOf(ai.quenderin.core.FileReadCapability(grantedFiles = { emptyMap() })) +
                    ai.quenderin.app.docWorkspaceCapabilities({ null }, ai.quenderin.app.DocUndoJournal()) +
                    ai.quenderin.app.devicePerceptionCapabilities(context)
            }
            Caption(stringResource(R.string.settings_always_on_tools))
            // Opt-in "Deeper reasoning" for the AGENT (distinct from chat's Deep thinking) — the twin of
            // the iOS Settings → Agent "Deeper reasoning" toggle. Writes the SAME "agent.deliberation"
            // key the Agent screen reads live at run time. Self-contained (local state + direct prefs
            // write) like the consent switches below.
            run {
                val agentPrefs = remember { context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE) }
                var deliberation by remember { mutableStateOf(agentPrefs.getBoolean("agent.deliberation", false)) }
                fun updateDeliberation(on: Boolean) {
                    deliberation = on
                    agentPrefs.edit().putBoolean("agent.deliberation", on).apply()
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .toggleable(value = deliberation, role = Role.Switch, onValueChange = ::updateDeliberation),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.settings_deeper_reasoning), color = MaterialTheme.colorScheme.onSurface)
                        Caption(stringResource(R.string.settings_agent_deliberation_hint))
                    }
                    Switch(
                        checked = deliberation,
                        onCheckedChange = null,
                    )
                }
            }
            gated.forEach { cap ->
                var granted by remember { mutableStateOf(consent.isGranted(cap.name)) }
                fun updateGrant(value: Boolean) {
                    granted = value
                    consent.setGranted(cap.name, value)
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .toggleable(value = granted, role = Role.Switch, onValueChange = ::updateGrant),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(capabilityTitle(cap.name), color = MaterialTheme.colorScheme.onSurface)
                        Caption(capabilityPurpose(cap.name, cap.purpose))
                    }
                    Switch(
                        checked = granted,
                        onCheckedChange = null,
                    )
                }
            }
            val ledgerRows = remember {
                ai.quenderin.core.FileAuditLedger(java.io.File(context.filesDir, "agent-ledger.jsonl"))
                    .entries().takeLast(10).reversed()
            }
            if (ledgerRows.isNotEmpty()) {
                Caption(stringResource(R.string.settings_recent_agent_activity))
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
                    Caption(stringResource(R.string.settings_skills_count, skillCount))
                    TextButton(onClick = {
                        skillStore.clear()
                        skillCount = 0
                    }) {
                        Text(stringResource(R.string.settings_clear_skills))
                    }
                } else {
                    Caption(stringResource(R.string.settings_no_skills_yet))
                }
            }
        }

            if (page == SettingsPage.STORAGE) SettingsGroup(stringResource(R.string.settings_storage), showHeading = false) {
                LabeledRow(stringResource(R.string.settings_saved_conversations), conversationCount.toString())
                Caption(stringResource(R.string.settings_history_hint))
            }

            if (page == SettingsPage.STORAGE) SettingsGroup(stringResource(R.string.settings_downloaded_models)) {
                if (installedModels.isEmpty()) {
                    Caption(stringResource(R.string.settings_no_models_yet))
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
                                        stringResource(R.string.settings_active),
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
                                // Hoisted: stringResource() can't be called inside the semantics{} lambda.
                                val deleteDesc = stringResource(R.string.settings_delete_named, installed.model.label)
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
                                    modifier = Modifier.semantics { contentDescription = deleteDesc },
                                ) { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) }
                            }
                        }
                    }
                    LabeledRow(
                        stringResource(R.string.settings_total_on_device),
                        Formatter.formatShortFileSize(context, totalModelBytes),
                    )
                }
                Caption(stringResource(R.string.settings_delete_model_hint))
            }

            if (page == SettingsPage.PRIVACY) SettingsGroup(stringResource(R.string.settings_privacy_support), showHeading = false) {
                Caption(stringResource(R.string.ai_disclaimer))
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

        if (page == SettingsPage.PRIVACY) Caption(stringResource(R.string.entry_private_detail))
        Spacer(Modifier.height(24.dp))   // breathing room at the very bottom, above the nav bar
    }

    } // SaveableStateProvider

    if (showPicker) {
        ModalBottomSheet(onDismissRequest = { showPicker = false }) {
            ModelPickerSheet(
                currentModelId = model.id,
                onSelect = { picked ->
                    showPicker = false
                    onSelectModel(picked)
                },
            )
        }
    }
}

/**
 * Material selection feedback and semantics, with space for large text.
 */
@Composable
private fun PresetChip(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label, modifier = Modifier.padding(vertical = 6.dp)) },
        modifier = modifier.heightIn(min = 48.dp),
    )
}

/** A reading section within one settings page. */
@Composable
private fun SettingsGroup(title: String, showHeading: Boolean = true, content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (showHeading) NativeSectionLabel(title)
        content()
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
}

@Composable
private fun LabeledRow(title: String, value: String) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(title, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}


private enum class SettingsPage { ROOT, MODELS, RESPONSES, AGENT, MEMORY, STEP5, VISION, GRANITE, STORAGE, PRIVACY }

@Composable
private fun settingsPageTitle(page: SettingsPage): String = when (page) {
    SettingsPage.ROOT -> stringResource(R.string.settings_title)
    SettingsPage.MODELS -> stringResource(R.string.settings_model)
    SettingsPage.RESPONSES -> stringResource(R.string.settings_responses)
    SettingsPage.AGENT -> stringResource(R.string.settings_agent)
    SettingsPage.MEMORY -> stringResource(R.string.settings_memory)
    SettingsPage.STEP5 -> stringResource(R.string.settings_step5)
    SettingsPage.VISION -> stringResource(R.string.settings_vision)
    SettingsPage.GRANITE -> "Granite Switch 4.1 8B"
    SettingsPage.STORAGE -> stringResource(R.string.settings_storage)
    SettingsPage.PRIVACY -> stringResource(R.string.settings_privacy_support)
}
