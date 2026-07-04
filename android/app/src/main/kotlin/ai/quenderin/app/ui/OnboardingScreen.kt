package ai.quenderin.app.ui

import ai.quenderin.app.WorkManagerModelDownloader
import ai.quenderin.core.AndroidDeviceProfile
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.DiskSpace
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelDownloader
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelSelection
import ai.quenderin.core.OnboardingModel
import ai.quenderin.core.OnboardingPhase
import ai.quenderin.core.StorageCheckResult
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
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
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    engine: InferenceEngine,
    downloader: ModelDownloader,
    probe: () -> AndroidDeviceProfile,
    conversations: ConversationPersistence,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var phase by remember { mutableStateOf<OnboardingPhase>(OnboardingPhase.Idle) }
    val onboarding = remember {
        // SharedPreferences backs the core's remember/recall seam (twin of the Swift UserDefaults
        // default); the file check points at the downloader's models dir under filesDir.
        val prefs = context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE)
        val modelsDir = File(context.filesDir, "models")
        OnboardingModel(
            engine,
            downloader,
            recallActiveModelID = { prefs.getString(OnboardingModel.ACTIVE_MODEL_PREFS_KEY, null) },
            rememberActiveModelID = { id -> prefs.edit().putString(OnboardingModel.ACTIVE_MODEL_PREFS_KEY, id).apply() },
            activeModelFileExists = { File(modelsDir, it.filename).isFile },
        ).apply { onChange = { phase = it } }
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

    when (val current = phase) {
        is OnboardingPhase.Ready -> MainTabs(
            engine = engine,
            model = current.model,
            conversations = conversations,
            // Reuse the onboarding install flow: download (if needed) → load → swap. Blocking → IO.
            onSelectModel = { picked -> scope.launch(Dispatchers.IO) { onboarding.acceptAndPrepare(picked) } },
        )
        else -> {
            var showPicker by remember { mutableStateOf(false) }
            OnboardingScreen(
                phase = current,
                selection = onboarding.selection,
                onStart = { onboarding.start(probe()) },   // world-class selector path
                onAccept = { model -> scope.launch(Dispatchers.IO) { onboarding.acceptAndPrepare(model) } },
                onChoose = { showPicker = true },
                onCancel = { model -> (downloader as? WorkManagerModelDownloader)?.cancel(model) },
                storageCheck = { model ->
                    DiskSpace.check(model, availableBytes = android.os.StatFs(context.filesDir.path).availableBytes)
                },
            )
            // The recommendation is a default, not a cage: the full catalog one tap away.
            if (showPicker) {
                ModalBottomSheet(onDismissRequest = { showPicker = false }) {
                    ModelPickerSheet(
                        currentModelId = (current as? OnboardingPhase.Recommended)?.model?.id ?: "",
                        onSelect = { picked ->
                            showPicker = false
                            scope.launch(Dispatchers.IO) { onboarding.acceptAndPrepare(picked) }
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
            AmbientGlow()   // slow-breathing background wash so the screen is never dead-static

            Column(
                modifier = Modifier.fillMaxSize().padding(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    "Quenderin",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "An AI that runs on your phone — even offline.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

                Spacer(Modifier.height(36.dp))

                // The living brand mark: a breathing core whose behaviour reads the current phase
                // (scanning while probing, a progress ring while downloading, a fast pulse while loading).
                ModelCore(phase = phase, fraction = animFraction)

                Spacer(Modifier.height(28.dp))

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
                    "Private by design — no account, no cloud, no tracking.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Button(onClick = onStart) { Text("Get started") }
            }

            is OnboardingPhase.Probing ->
                Text(
                    "Checking your device…",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

            is OnboardingPhase.Recommended -> {
                Text(
                    "RECOMMENDED FOR YOUR DEVICE",
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
                    phase.model.sizeLabel,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    phase.fitness.message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                selection?.let { sel ->
                    Spacer(Modifier.height(8.dp))
                    Text(
                        sel.thermalBattery.chatVerdict,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        sel.thermalBattery.sustainedVerdict,
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
                    Button(onClick = { onAccept(phase.model) }) { Text("Download & continue") }
                    TextButton(onClick = onChoose) { Text("Choose a different model…") }
                } else {
                    StorageShortfallCard(storage)
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = onChoose) { Text("Choose a smaller model") }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Or free up storage and come back.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            is OnboardingPhase.Downloading -> {
                val pct = (fraction * 100).toInt().coerceIn(0, 100)
                Text(
                    "Downloading",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    phase.model.label,
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics {
                        progressBarRangeInfo = ProgressBarRangeInfo(fraction, 0f..1f)
                        stateDescription = "Downloading ${phase.model.label}, $pct percent"
                    },
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "${phase.model.sizeLabel} · one time, then it's yours offline",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(6.dp))
                // A multi-GB download must never be a trap: cancel returns to the recommendation
                // (the engine keeps the .part, so a retry resumes).
                TextButton(onClick = { onCancel(phase.model) }) { Text("Cancel") }
            }

            is OnboardingPhase.Loading ->
                Text(
                    "Warming up ${phase.model.label}…",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

            is OnboardingPhase.Ready ->
                Text("Ready.", style = MaterialTheme.typography.titleMedium)

            is OnboardingPhase.Failed -> {
                Text("Couldn't get set up", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp))
                Text(
                    phase.reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Button(onClick = onStart) { Text("Try again") }
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
                    "  Not enough free space",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = warn,
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "This model needs ~${gb(storage.requiredBytes)} GB — your phone has ${gb(storage.availableBytes)} GB free.",
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
    val isProbing = phase is OnboardingPhase.Probing
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
