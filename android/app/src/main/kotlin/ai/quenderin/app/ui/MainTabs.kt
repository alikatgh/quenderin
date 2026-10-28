package ai.quenderin.app.ui

import ai.quenderin.app.R
import ai.quenderin.core.CalculatorTool
import ai.quenderin.core.ChatModel
import ai.quenderin.core.ConversationCoordinator
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.DateCalcTool
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.UnitConverterTool
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.testTag
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Four peer destinations share the loaded local engine. Material navigation adapts to the current
 * window while retained destination layers preserve the original coroutine and draft ownership.
 */
@Composable
fun MainTabs(
    engine: InferenceEngine,
    model: ModelEntry,
    conversations: ConversationPersistence,
    onSelectModel: (ModelEntry) -> Unit,
    onOpenDeepSeek: () -> Unit = {},
    onOpenComputer: () -> Unit = {},
    automaticEnabled: Boolean = false,
    onAutomaticChange: (Boolean) -> Unit = {},
    automaticDescription: () -> String = { "Estimated speed · current local model" },
    modelPreparationMessage: String? = null,
    captureLocalTurnIntent: () -> ai.quenderin.core.LocalTurnIntent = { ai.quenderin.core.LocalTurnIntent(0, null, true) },
    prepareAutomaticTurn: (ai.quenderin.core.AutomaticChatRequest, Boolean, Boolean, String?, ai.quenderin.core.LocalTurnIntent, () -> Boolean) -> ai.quenderin.core.PreparedLocalTurn? = { _, _, _, _, _, _ -> ai.quenderin.core.PreparedLocalTurn(model) { true } },
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    // "Deep thinking" preference — off by default (fast, direct replies). Mirrored onto the real engine so
    // the generation path reads it; a no-op for the mock/scripted engines.
    var deepThinking by remember { mutableStateOf(engine.thinkingEnabled()) }
    LaunchedEffect(deepThinking) { engine.setThinkingEnabled(deepThinking) }
    // The current window, including split screen, selects the native navigation pattern.
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 600.dp
        val destinations = listOf(
            Triple(NavKind.Chat, stringResource(R.string.tab_chat), 0),
            Triple(NavKind.Agent, stringResource(R.string.tab_agent), 1),
            Triple(NavKind.Images, stringResource(R.string.tab_images), 3),
            Triple(NavKind.Settings, stringResource(R.string.tab_settings), 2),
        )
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            bottomBar = {
                if (!wide) NavigationBar(containerColor = Quenderin.colors.navigationBar) {
                    destinations.forEach { (kind, label, index) ->
                        NavigationBarItem(
                            selected = tab == index,
                            onClick = { tab = index },
                            icon = { NavIcon(kind, tab == index) },
                            label = { Text(label) },
                            modifier = Modifier.testTag("nav.${kind.name.lowercase()}"),
                        )
                    }
                }
            },
        ) { pad ->
            // Consuming Scaffold padding lets a descendant imePadding dock the composer to the
            // keyboard instead of adding the navigation height a second time.
            Row(Modifier.fillMaxSize().padding(pad).consumeWindowInsets(pad)) {
                if (wide) NavigationRail(containerColor = Quenderin.colors.navigationBar) {
                    destinations.forEach { (kind, label, index) ->
                        NavigationRailItem(
                            selected = tab == index,
                            onClick = { tab = index },
                            icon = { NavIcon(kind, tab == index) },
                            label = { Text(label) },
                            modifier = Modifier.testTag("nav.${kind.name.lowercase()}"),
                        )
                    }
                }
                Box(Modifier.weight(1f).fillMaxSize()) {
                    // Keep every peer destination composed so tab changes retain drafts and jobs.
                    RetainedDestination(visible = tab == 0) {
                        ChatTab(
                            engine = engine,
                            model = model,
                            persistence = conversations,
                            onSelectModel = onSelectModel,
                            deepThinking = deepThinking,
                            onDeepThinkingChange = { deepThinking = it },
                            onOpenAgent = { tab = 1 },
                            automaticEnabled = automaticEnabled,
                            automaticDescription = automaticDescription,
                            modelPreparationMessage = modelPreparationMessage,
                            captureLocalTurnIntent = captureLocalTurnIntent,
                            prepareAutomaticTurn = prepareAutomaticTurn,
                        )
                    }
                    RetainedDestination(visible = tab == 1) {
                        AgentScreen(
                            engine = engine,
                            tools = listOf(CalculatorTool(), UnitConverterTool(), DateCalcTool()),
                            handoffTick = tab,
                        )
                    }
                    RetainedDestination(visible = tab == 2) {
                        SettingsScreen(
                            onOpenDeepSeek = onOpenDeepSeek,
                            onOpenComputer = onOpenComputer,
                            active = tab == 2,
                            suspendForSpecialist = engine::suspendForSpecialist,
                            model = model,
                            persistence = conversations,
                            onSelectModel = onSelectModel,
                            deepThinking = deepThinking,
                            onDeepThinkingChange = { deepThinking = it },
                            automaticEnabled = automaticEnabled,
                            onAutomaticChange = onAutomaticChange,
                            automaticDescription = automaticDescription,
                        )
                    }
                    RetainedDestination(visible = tab == 3) {
                        ImageGenerationScreen(suspendForSpecialist = engine::suspendForSpecialist, active = tab == 3)
                    }
                }
            }
        }
    }
}

@Composable
internal fun RetainedDestination(visible: Boolean, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().tabVisibility(visible)) {
        CompositionLocalProvider(LocalDestinationActive provides visible, content = content)
    }
}

/**
 * The Chat tab: a WhatsApp-style two-level flow. Owns the [ConversationCoordinator] (and its live
 * `summaries`), and switches between the conversation LIST and an open CONVERSATION. Keeping the
 * coordinator here — above the list/conversation swap — means both views share one source of truth and
 * survive the swap.
 *
 * Conversation lifecycle operations continue through the coordinator, which owns cancellation and
 * transcript persistence. Tab changes keep this owner composed; leaving the conversation follows
 * the existing coordinator policy for an unfinished reply.
 */
@Composable
private fun ChatTab(
    engine: InferenceEngine,
    model: ModelEntry,
    persistence: ConversationPersistence,
    onSelectModel: (ModelEntry) -> Unit,
    deepThinking: Boolean,
    onDeepThinkingChange: (Boolean) -> Unit,
    onOpenAgent: () -> Unit = {},
    automaticEnabled: Boolean = false,
    automaticDescription: () -> String = { "Estimated speed · current local model" },
    modelPreparationMessage: String? = null,
    captureLocalTurnIntent: () -> ai.quenderin.core.LocalTurnIntent = { ai.quenderin.core.LocalTurnIntent(0, null, true) },
    prepareAutomaticTurn: (ai.quenderin.core.AutomaticChatRequest, Boolean, Boolean, String?, ai.quenderin.core.LocalTurnIntent, () -> Boolean) -> ai.quenderin.core.PreparedLocalTurn? = { _, _, _, _, _, _ -> ai.quenderin.core.PreparedLocalTurn(model) { true } },
) {
    val coordinator = remember { ConversationCoordinator(ChatModel(engine), persistence) }
    var summaries by remember { mutableStateOf(coordinator.summaries) }
    // First-open after onboarding: skip the empty Chats list (a dead end) and land in a blank
    // chat with starter chips. Returning users with saved threads still see the list.
    var inConversation by remember {
        mutableStateOf(coordinator.summaries.isEmpty())
    }
    LaunchedEffect(coordinator) {
        coordinator.onChange = { summaries = it }
        if (coordinator.summaries.isEmpty() && !inConversation) {
            coordinator.startNew()
            inConversation = true
        } else if (coordinator.summaries.isEmpty() && inConversation) {
            // Ensure an open conversation exists for the empty-state starters.
            coordinator.startNew()
        }
    }

    BackHandler(enabled = LocalDestinationActive.current && inConversation) {
        coordinator.persist()
        inConversation = false
    }
    if (inConversation) {
        ChatScreen(
            coordinator = coordinator,
            model = model,
            onBack = { coordinator.persist(); inConversation = false },
            onSelectModel = onSelectModel,
            deepThinking = deepThinking,
            onDeepThinkingChange = onDeepThinkingChange,
            onOpenAgent = onOpenAgent,
            automaticEnabled = automaticEnabled,
            automaticDescription = automaticDescription,
            modelPreparationMessage = modelPreparationMessage,
            captureLocalTurnIntent = captureLocalTurnIntent,
            prepareAutomaticTurn = prepareAutomaticTurn,
        )
    } else {
        ConversationListScreen(
            summaries = summaries,
            model = model,
            onOpen = { id -> coordinator.open(id); inConversation = true },
            onNew = { coordinator.startNew(); inConversation = true },
            onDelete = { id -> coordinator.delete(id) },
        )
    }
}

/**
 * Hides an inactive tab (alpha, stacking order, a11y) while keeping it composed, instead of
 * tearing it down — so its `rememberCoroutineScope()`-launched work isn't cancelled by
 * switching tabs. A no-ripple clickable with an empty lambda "swallows" touches on the hidden
 * layers so they can't be tapped through to whatever sits beneath the visible one.
 */
@Composable
private fun Modifier.tabVisibility(visible: Boolean): Modifier = this
    .alpha(if (visible) 1f else 0f)
    .zIndex(if (visible) 1f else 0f)
    .then(if (visible) Modifier else Modifier.clearAndSetSemantics {})
    .then(
        if (visible) Modifier.pointerInput(Unit) {
            // A full-size hit region keeps blank-space taps in the visible destination.
            // Do not consume events: its children retain their normal Material gestures.
            awaitPointerEventScope {
                while (true) awaitPointerEvent()
            }
        } else Modifier.clickable(
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
        ) {},
    )

private enum class NavKind { Chat, Agent, Images, Settings }

/**
 * Crisp, theme-tinted line icons drawn in Compose — replacing the full-colour emoji that clashed with
 * the app's palette. Outline style, coloured by selection (primary when active, muted otherwise).
 */
@Composable
private fun NavIcon(kind: NavKind, selected: Boolean) {
    // onSecondaryContainer pairs with the secondaryContainer pill behind it (guaranteed contrast);
    // primary-on-pill measured ≈2.65:1 in the dark scheme, below the 3:1 non-text minimum.
    val color = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(Modifier.size(24.dp).clearAndSetSemantics {}) {
        val s = size.minDimension
        val sw = 1.9.dp.toPx()
        when (kind) {
            NavKind.Chat -> {
                drawRoundRect(
                    color,
                    topLeft = Offset(s * 0.12f, s * 0.14f),
                    size = Size(s * 0.76f, s * 0.54f),
                    cornerRadius = CornerRadius(s * 0.18f),
                    style = Stroke(sw),
                )
                // little tail bottom-left
                drawLine(color, Offset(s * 0.30f, s * 0.68f), Offset(s * 0.30f, s * 0.86f), sw, StrokeCap.Round)
                drawLine(color, Offset(s * 0.30f, s * 0.86f), Offset(s * 0.48f, s * 0.68f), sw, StrokeCap.Round)
                for (fx in listOf(0.34f, 0.5f, 0.66f)) drawCircle(color, s * 0.035f, Offset(s * fx, s * 0.41f))
            }
            NavKind.Agent -> {
                // 4-point "AI spark": a concave star.
                val cx = s * 0.5f; val cy = s * 0.5f; val r = s * 0.40f; val k = r * 0.18f
                val p = Path().apply {
                    moveTo(cx, cy - r)
                    quadraticBezierTo(cx + k, cy - k, cx + r, cy)
                    quadraticBezierTo(cx + k, cy + k, cx, cy + r)
                    quadraticBezierTo(cx - k, cy + k, cx - r, cy)
                    quadraticBezierTo(cx - k, cy - k, cx, cy - r)
                    close()
                }
                drawPath(p, color, style = Stroke(sw, join = StrokeJoin.Round))
            }
            NavKind.Images -> {
                drawRoundRect(color, topLeft = Offset(s * 0.12f, s * 0.14f), size = Size(s * 0.76f, s * 0.72f),
                    cornerRadius = CornerRadius(s * 0.10f), style = Stroke(sw))
                drawCircle(color, s * 0.07f, Offset(s * 0.66f, s * 0.35f))
                val mountain = Path().apply {
                    moveTo(s * 0.18f, s * 0.77f); lineTo(s * 0.41f, s * 0.46f)
                    lineTo(s * 0.59f, s * 0.66f); lineTo(s * 0.72f, s * 0.53f); lineTo(s * 0.83f, s * 0.76f)
                }
                drawPath(mountain, color, style = Stroke(sw, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            NavKind.Settings -> {
                val cx = s * 0.5f; val cy = s * 0.5f
                drawCircle(color, s * 0.17f, Offset(cx, cy), style = Stroke(sw))
                for (i in 0 until 8) {
                    val a = (i * PI / 4).toFloat()
                    drawLine(
                        color,
                        Offset(cx + cos(a) * s * 0.26f, cy + sin(a) * s * 0.26f),
                        Offset(cx + cos(a) * s * 0.40f, cy + sin(a) * s * 0.40f),
                        sw, StrokeCap.Round,
                    )
                }
            }
        }
    }
}
