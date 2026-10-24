package ai.quenderin.app.ui

import androidx.compose.ui.res.stringResource
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.saveable.rememberSaveable
import ai.quenderin.app.R
import ai.quenderin.app.Step5Controller
import ai.quenderin.app.VisionController
import ai.quenderin.app.GraniteController
import ai.quenderin.app.AndroidDeepSeekVault
import ai.quenderin.app.AndroidDeepSeekPersistence
import ai.quenderin.app.DeepSeekController
import ai.quenderin.app.DeepSeekOkHttpTransport

import ai.quenderin.app.WorkManagerModelDownloader
import ai.quenderin.core.AndroidDeviceProfile
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.DiskSpace
import ai.quenderin.core.DownloadPolicy
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelDownloader
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelSelection
import ai.quenderin.core.NetworkStatus
import ai.quenderin.core.OnboardingModel
import ai.quenderin.core.OnboardingPhase
import ai.quenderin.core.StorageCheckResult
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.TextButton
import androidx.compose.ui.platform.LocalContext
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Top-level router: drives [OnboardingModel] until it reaches Ready, then hands off to
 * [ChatScreen]. Maps the core's listener (`onChange`) into Compose state and runs the
 * blocking download/load on [Dispatchers.IO]. Twin of iOS `RootView`.
 */
/**
 * Q-583: map the device's active connection to the core's [NetworkStatus] so the download gate can
 * refuse a large cellular pull. Uses the NetworkCapabilities API (API 23+): anything with internet
 * that isn't cellular (Wi-Fi, Ethernet) is treated as unmetered → WIFI; a positive cellular transport
 * → CELLULAR (gated); no active/internet-capable network → NONE.
 */
private fun currentNetworkStatus(context: android.content.Context): NetworkStatus {
    val cm = context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        ?: return NetworkStatus.NONE
    val network = cm.activeNetwork ?: return NetworkStatus.NONE
    val caps = cm.getNetworkCapabilities(network) ?: return NetworkStatus.NONE
    return when {
        !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> NetworkStatus.NONE
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkStatus.CELLULAR
        else -> NetworkStatus.WIFI
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    engine: InferenceEngine,
    downloader: ModelDownloader,
    probe: () -> AndroidDeviceProfile,
    conversations: ConversationPersistence,
    performanceStore: ai.quenderin.core.InferencePerformanceStore,
    automaticProfile: (ModelEntry, ai.quenderin.core.AutomaticChatRequest?, List<ai.quenderin.core.InferencePerformanceSample>) -> List<ai.quenderin.core.AutomaticExecutionProfile>,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var phase by remember { mutableStateOf<OnboardingPhase>(OnboardingPhase.Idle) }
    var readyModel by remember { mutableStateOf<ModelEntry?>(null) }
    val selectionPrefs = remember { context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE) }
    val automaticMode = remember { ai.quenderin.core.AutomaticSelectionMode(
        read = { selectionPrefs.getBoolean(ai.quenderin.core.AutomaticSelectionMode.PREFERENCE_KEY, false) },
        write = { selectionPrefs.edit().putBoolean(ai.quenderin.core.AutomaticSelectionMode.PREFERENCE_KEY, it).apply() }) }
    var automaticEnabled by remember { mutableStateOf(automaticMode.enabled()) }
    var manualStateRevision by remember { mutableStateOf(0L) }
    val onboarding = remember {
        // SharedPreferences backs the core's remember/recall seam (twin of the Swift UserDefaults
        // default); the file check points at the downloader's models dir under filesDir.
        val prefs = context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
        val modelsDir = File(context.filesDir, "models")
        OnboardingModel(
            engine,
            downloader,
            recallActiveModelID = {
                if (automaticMode.enabled()) prefs.getString(OnboardingModel.ACTIVE_MODEL_PREFS_KEY, null)
                else prefs.getString(ai.quenderin.core.AutomaticSelectionMode.MANUAL_MODEL_KEY, null)
                    ?: prefs.getString(OnboardingModel.ACTIVE_MODEL_PREFS_KEY, null)
            },
            rememberActiveModelID = { id ->
                prefs.edit().putString(OnboardingModel.ACTIVE_MODEL_PREFS_KEY, id).also {
                    if (!automaticMode.enabled() && !prefs.contains(ai.quenderin.core.AutomaticSelectionMode.MANUAL_MODEL_KEY))
                        it.putString(ai.quenderin.core.AutomaticSelectionMode.MANUAL_MODEL_KEY, id)
                }.apply()
            },
            activeModelFileExists = { model ->
                ai.quenderin.core.ModelArtifacts.filenames(model).all { File(modelsDir, it).isFile }
            },
            // Q-583 (P0): wire the LIVE network status from ConnectivityManager so the core's cellular
            // gate (Q-271 twin) actually bites — it defaults to WIFI, so without this the gate was dead.
            // Read at download time (not captured once) so a Wi-Fi→cellular switch is seen. Policy is the
            // safe WIFI_ONLY default; Q-578 adds a Settings opt-in toggle.
            networkStatus = { currentNetworkStatus(context) },
            downloadPolicy = { DownloadPolicy.WIFI_ONLY },
            // Disk preflight for the live install path (twin of Swift storageCheck): refuse a
            // download that can't finish, instead of dying at 95% with a generic failure.
            availableDiskBytes = { android.os.StatFs(context.filesDir.path).availableBytes },
            verifiedInstalledPath = { model ->
                if (ai.quenderin.core.InferencePerformanceIdentity.artifact(model) == null) null else {
                    val path = File(modelsDir, model.filename).absolutePath
                    runCatching { ai.quenderin.core.ModelArtifactVerificationReceipts.process.verify(model, path)?.path }.getOrNull()
                }
            },
        ).apply { onChange = { next -> scope.launch(Dispatchers.Main.immediate) {
            if (next is OnboardingPhase.Ready) readyModel = next.model
            phase = next
        } } }
    }
    val automatic = remember { ai.quenderin.app.AutomaticModelController(engine, onboarding, automaticMode,
        performanceStore, File(context.filesDir, "models"), probe, automaticProfile,
        rememberManualModel = { selectionPrefs.edit().putString(ai.quenderin.core.AutomaticSelectionMode.MANUAL_MODEL_KEY, it).apply() },
        onManualStateChanged = { scope.launch(Dispatchers.Main.immediate) { manualStateRevision++ } }) }
    fun selectManual(model: ModelEntry) {
        val intent = automatic.manualChoice(model)
        automaticEnabled = false
        scope.launch(Dispatchers.IO) { automatic.confirmManualChoice(intent) }
    }
    // Relaunch fast-path: restore the last successfully-loaded model straight to Ready instead of
    // replaying first-run onboarding. Blocking (integrity re-check + load) → IO, like every other
    // core call here.
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { onboarding.restoreAtLaunch() } }

    // First launch ever: one calm page of who Quenderin is, before any setup (twin of iOS
    // WelcomeGate). The same "quenderin" prefs file the model-restore seam uses.
    var needsWelcome by remember {
        val prefs = context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
        mutableStateOf(!prefs.getBoolean("hasWelcomed", false))
    }
    if (needsWelcome) {
        WelcomeScreen(onContinue = {
            context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
                .edit().putBoolean("hasWelcomed", true).apply()
            needsWelcome = false
        })
        return
    }

    // Nobody uses the app without agreeing that AI output is their own responsibility —
    // separate flag from hasWelcomed ON PURPOSE, so existing users also accept once
    // (twin of iOS ConsentGate).
    var needsConsent by remember {
        val prefs = context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
        mutableStateOf(!prefs.getBoolean("disclaimerAccepted", false))
    }
    if (needsConsent) {
        ConsentScreen(onAgree = {
            context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
                .edit().putBoolean("disclaimerAccepted", true).apply()
            needsConsent = false
        })
        return
    }

    var showDeepSeek by rememberSaveable { mutableStateOf(false) }
    var showComputer by rememberSaveable {
        mutableStateOf(context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE).getBoolean("remoteComputerOpen", false))
    }
    val remoteComputer = remember { ai.quenderin.app.RemoteHarnessController(context) }
    androidx.compose.runtime.DisposableEffect(remoteComputer) { onDispose { remoteComputer.close() } }
    fun openComputer() {
        context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE).edit().putBoolean("remoteComputerOpen", true).apply()
        showComputer = true
    }
    if (showComputer) {
        androidx.compose.ui.window.Dialog(onDismissRequest = {
            remoteComputer.disconnect(); showComputer = false
            context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE).edit().putBoolean("remoteComputerOpen", false).apply()
        }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false, securePolicy = androidx.compose.ui.window.SecureFlagPolicy.SecureOn)) {
            RemoteHarnessScreen(remoteComputer, onBack = {
                remoteComputer.disconnect(); showComputer = false
                context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE).edit().putBoolean("remoteComputerOpen", false).apply()
            })
        }
    }
    if (showDeepSeek) {
        val deepSeek = remember {
            val vault = AndroidDeepSeekVault(context)
            DeepSeekController(vault, DeepSeekOkHttpTransport(vault), AndroidDeepSeekPersistence(context))
        }
        androidx.compose.runtime.DisposableEffect(deepSeek) { onDispose { deepSeek.close() } }
        // Keep the local shell composed beneath this native full-screen destination so a local
        // draft, attachment, open conversation and run owner survive the cloud visit.
        androidx.compose.ui.window.Dialog(onDismissRequest = { showDeepSeek = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false, securePolicy = androidx.compose.ui.window.SecureFlagPolicy.SecureOn)) {
            DeepSeekScreen(deepSeek, onBack = { showDeepSeek = false })
        }
    }
    var showImagesBeforeChat by rememberSaveable { mutableStateOf(false) }
    var showStep5BeforeChat by remember { mutableStateOf(false) }
    val step5BeforeChat = remember { Step5Controller() }
    var showVisionBeforeChat by remember { mutableStateOf(false) }
    val visionBeforeChat = remember { VisionController(context, engine::suspendForSpecialist) }
    androidx.compose.runtime.DisposableEffect(visionBeforeChat) { onDispose { visionBeforeChat.close() } }
    var showGraniteBeforeChat by remember { mutableStateOf(false) }
    val graniteBeforeChat = remember { GraniteController(context, engine::suspendForSpecialist) }
    androidx.compose.runtime.DisposableEffect(graniteBeforeChat) { onDispose { graniteBeforeChat.close() } }
    if (showGraniteBeforeChat) {
        BackHandler { showGraniteBeforeChat = false }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            TextButton(onClick = { showGraniteBeforeChat = false }) { Text("Back to setup") }
            GraniteScreen(graniteBeforeChat)
        }
        return
    }
    if (showVisionBeforeChat) {
        BackHandler { showVisionBeforeChat = false }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            TextButton(onClick = { showVisionBeforeChat = false }) { Text("Back to setup") }
            VisionScreen(visionBeforeChat)
        }
        return
    }
    if (showStep5BeforeChat) {
        BackHandler { showStep5BeforeChat = false }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            TextButton(onClick = { showStep5BeforeChat = false }) { Text("Back to setup") }
            Step5Screen(step5BeforeChat)
        }
        return
    }
    if (showImagesBeforeChat) {
        BackHandler { showImagesBeforeChat = false }
        Column(Modifier.fillMaxSize()) {
            TextButton(onClick = { showImagesBeforeChat = false }) { Text("Back to setup") }
            Box(Modifier.weight(1f)) { ImageGenerationScreen(suspendForSpecialist = engine::suspendForSpecialist) }
        }
        return
    }
    // Retain the composed conversation owner/draft through both automatic and manual model loads.
    when (val current = readyModel?.let { OnboardingPhase.Ready(it) } ?: phase) {
        is OnboardingPhase.Ready -> MainTabs(
            engine = engine,
            model = current.model,
            conversations = conversations,
            // Reuse the onboarding install flow: download (if needed) → load → swap. Blocking → IO.
            onSelectModel = ::selectManual,
            automaticEnabled = automaticEnabled,
            onAutomaticChange = {
                automatic.setAutomaticEnabled(it); automaticEnabled = automaticMode.enabled()
            },
            automaticDescription = { automatic.description },
            modelPreparationMessage = when (val state = phase) {
                is OnboardingPhase.Ready -> manualStateRevision.let { automatic.manualPreparationMessage }
                is OnboardingPhase.Failed -> state.reason
                else -> "Preparing the selected local model… Your draft is kept."
            },
            captureLocalTurnIntent = automatic::captureTurnIntent,
            prepareAutomaticTurn = automatic::prepareTurn,
            onOpenDeepSeek = { showDeepSeek = true },
            onOpenComputer = ::openComputer,
        )
        else -> {
            var showPicker by remember { mutableStateOf(false) }
            Box(Modifier.fillMaxSize()) {
            OnboardingScreen(
                phase = current,
                selection = onboarding.selection,
                onStart = { onboarding.start(probe()) },   // world-class selector path
                onAccept = ::selectManual,
                onChoose = { showPicker = true },
                onCancel = { model -> (downloader as? WorkManagerModelDownloader)?.cancel(model) },
                storageCheck = { model ->
                    DiskSpace.check(model, availableBytes = android.os.StatFs(context.filesDir.path).availableBytes,
                        remainingDownloadBytes = ai.quenderin.core.ModelArtifacts.estimatedRemainingDownloadBytes(
                            model, File(context.filesDir, "models").absolutePath))
                },
            )
                var showOtherModels by remember { mutableStateOf(false) }
                Row(modifier = Modifier.align(Alignment.TopStart).padding(12.dp)) {
                    TextButton(onClick = ::openComputer) { Text("My computer") }
                    TextButton(onClick = { showDeepSeek = true }) { Text("DeepSeek cloud") }
                }
                Box(modifier = Modifier.align(Alignment.TopEnd).padding(12.dp)) {
                    TextButton(onClick = { showOtherModels = true }) { Text("More models") }
                    androidx.compose.material3.DropdownMenu(expanded = showOtherModels, onDismissRequest = { showOtherModels = false }) {
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Still image") }, onClick = { showOtherModels = false; showVisionBeforeChat = true })
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Step 5") }, onClick = { showOtherModels = false; showStep5BeforeChat = true })
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Images") }, onClick = { showOtherModels = false; showImagesBeforeChat = true })
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Granite 4.1") }, onClick = { showOtherModels = false; showGraniteBeforeChat = true })
                    }
                }
            }
            // The recommendation is a default, not a cage: the full catalog one tap away.
            if (showPicker) {
                ModalBottomSheet(onDismissRequest = { showPicker = false }) {
                    ModelPickerSheet(
                        // Nothing is installed yet during onboarding: passing the recommendation as
                        // "current" tagged it Current and DISABLED its row (iOS passes none). The
                        // recommended row keeps its own tag; the user may still pick it here.
                        currentModelId = "",
                        onSelect = { picked ->
                            showPicker = false
                            selectManual(picked)
                        },
                    )
                }
            }
        }
    }
}

@Composable
fun OnboardingScreen(
    phase: OnboardingPhase,
    selection: ModelSelection?,
    onStart: () -> Unit,
    onAccept: (ModelEntry) -> Unit,
    onChoose: () -> Unit = {},
    onCancel: (ModelEntry) -> Unit = {},
    storageCheck: (ModelEntry) -> StorageCheckResult = { StorageCheckResult(true, 0, 0, "") },
) {
    // Smoothly-eased download fraction so the ring glides to each new value instead of snapping.
    val targetFraction = (phase as? OnboardingPhase.Downloading)?.fraction?.toFloat() ?: 0f
    val animFraction by animateFloatAsState(
        targetValue = targetFraction,
        animationSpec = tween(durationMillis = 450, easing = FastOutSlowInEasing),
        label = "downloadFraction",
    )

    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize()) {
            // Keep the dark screen canvas uniformly black, including setup/loading/error phases.
            if (!isSystemInDarkTheme()) AmbientGlow()

            val isDownloading = phase is OnboardingPhase.Downloading
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(28.dp)
                    .then(
                        if (isDownloading) Modifier.verticalScroll(rememberScrollState())
                        else Modifier,
                    ),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = if (isDownloading) Arrangement.Top else Arrangement.Center,
            ) {
                Text(
                    "Quenderin",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(R.string.onboarding_tagline),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

                // During multi-GB download the compact progress card + mini-game take the space —
                // the big ModelCore is redundant with the percent bar.
                if (!isDownloading) {
                    Spacer(Modifier.height(36.dp))
                    ModelCore(phase = phase, fraction = animFraction)
                    Spacer(Modifier.height(28.dp))
                } else {
                    Spacer(Modifier.height(16.dp))
                }

                // Phase-specific copy + actions, crossfaded so a phase change glides instead of snapping.
                // contentKey keys on the phase TYPE, so a download's per-percent updates don't re-run the
                // fade — only genuine phase transitions do.
                AnimatedContent(
                    targetState = phase,
                    contentKey = { it.animKey() },
                    transitionSpec = {
                        fadeIn(tween(280)) togetherWith fadeOut(tween(200))
                    },
                    label = "phaseContent",
                ) { p ->
                    PhaseContent(
                        phase = p,
                        selection = selection,
                        fraction = animFraction,
                        onStart = onStart,
                        onAccept = onAccept,
                        onChoose = onChoose,
                        onCancel = onCancel,
                        storageCheck = storageCheck,
                    )
                }
            }
        }
    }
}

/** Stable key per phase kind, so [AnimatedContent] only transitions on a real phase change. */
private fun OnboardingPhase.animKey(): String = when (this) {
    is OnboardingPhase.Idle -> "idle"
    is OnboardingPhase.Probing -> "probing"
    is OnboardingPhase.Recommended -> "recommended"
    is OnboardingPhase.Downloading -> "downloading"
    is OnboardingPhase.Verifying -> "verifying"
    is OnboardingPhase.Loading -> "loading"
    is OnboardingPhase.Ready -> "ready"
    is OnboardingPhase.Failed -> "failed"
}

@Composable
private fun PhaseContent(
    phase: OnboardingPhase,
    selection: ModelSelection?,
    fraction: Float,
    onStart: () -> Unit,
    onAccept: (ModelEntry) -> Unit,
    onChoose: () -> Unit,
    onCancel: (ModelEntry) -> Unit,
    storageCheck: (ModelEntry) -> StorageCheckResult,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.widthIn(max = 340.dp),
    ) {
        when (phase) {
            is OnboardingPhase.Idle -> {
                Text(
                    stringResource(R.string.onboarding_private_line),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Button(onClick = onStart) { Text(stringResource(R.string.action_get_started)) }
            }

            is OnboardingPhase.Probing ->
                Text(
                    stringResource(R.string.onboarding_checking),
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

            is OnboardingPhase.Recommended -> {
                Text(
                    stringResource(R.string.onboarding_recommended_overline),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    phase.model.label,
                    style = MaterialTheme.typography.titleLarge,
                    textAlign = TextAlign.Center,
                )
                Text(
                    localizedSizeLabel(phase.model),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    // Selector path (production): recompose the rationale in the user's language from
                    // sel's structured fields. Band path (test-only): the English message stands.
                    selection?.let { localizedRationale(it) } ?: phase.fitness.message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                selection?.let { sel ->
                    // Storage honesty: a full phone gets a small model — say why, and that it's fixable.
                    localizedStorageLimited(sel)?.let { line ->
                        Spacer(Modifier.height(8.dp))
                        Text(
                            line,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        localizedChatVerdict(sel),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        localizedSustainedVerdict(sel),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
                Spacer(Modifier.height(20.dp))
                // The CTA adapts to reality (twin of the Apple onboarding): when the recommended
                // download fits, the primary action is Download; when it DOESN'T, the reason moves
                // into a calm structured card and the PRIMARY action becomes picking a model that
                // fits — never a disabled dead-end hero button.
                val storage = storageCheck(phase.model)
                if (storage.hasRoom) {
                    Button(onClick = { onAccept(phase.model) }) { Text(stringResource(R.string.onboarding_download_continue)) }
                    TextButton(onClick = onChoose) { Text(stringResource(R.string.onboarding_choose_different)) }
                } else {
                    StorageShortfallCard(storage)
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = onChoose) { Text(stringResource(R.string.onboarding_choose_smaller)) }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        stringResource(R.string.onboarding_free_up_storage),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            is OnboardingPhase.Downloading -> {
                // Multi-GB waits used to be a dead progress ring — offer tips + token-catch game.
                DownloadWaitPlayground(
                    modelLabel = phase.model.label,
                    sizeLabel = phase.model.sizeLabel.removeSuffix(" download"),
                    fraction = fraction,
                    onCancel = { onCancel(phase.model) },
                )
            }

            is OnboardingPhase.Verifying -> {
                Text(
                    stringResource(R.string.download_verification_title, phase.model.label),
                    style = MaterialTheme.typography.titleSmall,
                    textAlign = TextAlign.Center,
                )
                Text(
                    stringResource(R.string.download_verification_progress, phase.checkedFiles, phase.totalFiles),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(onClick = { onCancel(phase.model) }) {
                    Text(stringResource(R.string.action_cancel))
                }
            }

            is OnboardingPhase.Loading ->
                Text(
                    stringResource(R.string.onboarding_warming, phase.model.label),
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

            is OnboardingPhase.Ready ->
                Text(stringResource(R.string.onboarding_ready), style = MaterialTheme.typography.titleMedium)

            is OnboardingPhase.Failed -> {
                Text(stringResource(R.string.onboarding_setup_failed), style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp))
                Text(
                    phase.reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Button(onClick = onStart) { Text(stringResource(R.string.action_try_again)) }
            }
        }
    }
}

/**
 * Why the recommended model can't be installed, as a compact structured card — an orange status dot
 * + short headline + ONE plain-toned sentence with the two numbers that matter. Never a wall of
 * alarm text on the first-run screen. Twin of the Apple `StorageShortfallCard`.
 */
@Composable
private fun StorageShortfallCard(storage: StorageCheckResult) {
    fun gb(bytes: Long) = String.format("%.1f", bytes / 1_000_000_000.0)
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            val warn = androidx.compose.ui.graphics.Color(0xFFE8963A)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(7.dp)
                        .background(warn, androidx.compose.foundation.shape.CircleShape),
                )
                Text(
                    "  " + stringResource(R.string.onboarding_not_enough_space),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = warn,
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.onboarding_storage_needs, gb(storage.requiredBytes), gb(storage.availableBytes)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * The animated brand mark, drawn entirely in Compose (no bitmap assets → crisp at any density and
 * theme-correct). A glowing core "breathes"; concentric rings ripple outward to signal activity.
 * The behaviour reads the phase:
 *  - Probing  → a sweeping scan arc (we're inspecting the device).
 *  - Downloading → a determinate progress ring around the core showing [fraction], with a big % inside.
 *  - Loading  → a faster, tighter pulse (weights coming online).
 *  - Ready/other → a calm steady glow.
 */
@Composable
private fun ModelCore(phase: OnboardingPhase, fraction: Float) {
    val primary = MaterialTheme.colorScheme.primary
    val onSurfaceVariant = MaterialTheme.colorScheme.onSurfaceVariant

    val transition = rememberInfiniteTransition(label = "core")
    // A slow breath for the core, always running so the screen never looks frozen.
    val breath by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2600, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "breath",
    )
    // Ripple phase for the expanding rings.
    val ripple by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2800, easing = LinearEasing), RepeatMode.Restart),
        label = "ripple",
    )
    // Continuous rotation used by the probing scan sweep.
    val sweep by transition.animateFloat(
        initialValue = 0f, targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(1400, easing = LinearEasing), RepeatMode.Restart),
        label = "sweep",
    )

    val isDownloading = phase is OnboardingPhase.Downloading
    val isProbing = phase is OnboardingPhase.Probing || phase is OnboardingPhase.Verifying
    val isLoading = phase is OnboardingPhase.Loading
    // Loading pulses faster/tighter than the idle breath.
    val pulseAmount = if (isLoading) 0.10f else 0.05f
    val coreScale = 0.92f + breath * pulseAmount

    Box(contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(190.dp)) {
            val c = center
            val maxR = size.minDimension / 2f

            // Soft radial glow behind everything.
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(primary.copy(alpha = 0.28f), primary.copy(alpha = 0f)),
                    center = c,
                    radius = maxR,
                ),
                radius = maxR,
                center = c,
            )

            // Concentric ripple rings (three, staggered) — the "alive" signal.
            for (i in 0 until 3) {
                val p = (ripple + i / 3f) % 1f
                val r = maxR * (0.34f + p * 0.62f)
                val alpha = (1f - p) * 0.30f
                drawCircle(
                    color = primary.copy(alpha = alpha),
                    radius = r,
                    center = c,
                    style = Stroke(width = 1.5.dp.toPx()),
                )
            }

            val ringR = maxR * 0.66f
            val ringTopLeft = Offset(c.x - ringR, c.y - ringR)
            val ringSize = Size(ringR * 2f, ringR * 2f)

            if (isDownloading) {
                // Track + determinate progress arc around the core.
                drawArc(
                    color = primary.copy(alpha = 0.15f),
                    startAngle = -90f, sweepAngle = 360f, useCenter = false,
                    topLeft = ringTopLeft, size = ringSize,
                    style = Stroke(width = 7.dp.toPx(), cap = StrokeCap.Round),
                )
                drawArc(
                    color = primary,
                    startAngle = -90f, sweepAngle = 360f * fraction.coerceIn(0f, 1f), useCenter = false,
                    topLeft = ringTopLeft, size = ringSize,
                    style = Stroke(width = 7.dp.toPx(), cap = StrokeCap.Round),
                )
            } else if (isProbing) {
                // A rotating scan sweep: a short bright arc chasing around a faint track.
                drawArc(
                    color = primary.copy(alpha = 0.12f),
                    startAngle = -90f, sweepAngle = 360f, useCenter = false,
                    topLeft = ringTopLeft, size = ringSize,
                    style = Stroke(width = 5.dp.toPx(), cap = StrokeCap.Round),
                )
                drawArc(
                    color = primary,
                    startAngle = sweep, sweepAngle = 90f, useCenter = false,
                    topLeft = ringTopLeft, size = ringSize,
                    style = Stroke(width = 5.dp.toPx(), cap = StrokeCap.Round),
                )
            }

            // The breathing core.
            val coreR = maxR * 0.30f * coreScale
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(primary, primary.copy(alpha = 0.65f)),
                    center = c,
                    radius = coreR,
                ),
                radius = coreR,
                center = c,
            )
        }

        // Big percentage inside the ring while downloading (counts up smoothly via animFraction).
        if (isDownloading) {
            val pct = (fraction * 100).toInt().coerceIn(0, 100)
            Text(
                "$pct%",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

/** A slow, low-opacity radial wash that breathes behind the content so the screen has ambient life. */
@Composable
private fun AmbientGlow() {
    val primary = MaterialTheme.colorScheme.primary
    val transition = rememberInfiniteTransition(label = "ambient")
    val t by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(6000, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "ambientBreath",
    )
    Box(
        Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(0.dp)),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.maxDimension * (0.55f + t * 0.15f)
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(primary.copy(alpha = 0.10f + t * 0.05f), primary.copy(alpha = 0f)),
                    center = Offset(size.width * 0.5f, size.height * 0.32f),
                    radius = r,
                ),
                radius = r,
                center = Offset(size.width * 0.5f, size.height * 0.32f),
            )
        }
    }
}
