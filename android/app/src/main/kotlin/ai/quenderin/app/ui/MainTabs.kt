package ai.quenderin.app.ui

import ai.quenderin.app.R
import ai.quenderin.core.CalculatorTool
import ai.quenderin.core.ChatModel
import ai.quenderin.core.ConversationCoordinator
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.DateCalcTool
import ai.quenderin.core.EchoTool
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.LlamaEngine
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.UnitConverterTool
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * The post-onboarding shell: Chat + Agent tabs sharing the loaded model/engine. The Compose
 * twin of iOS `RootView`'s TabView. Emoji icons keep this free of the material-icons-extended
 * dependency. App/cliff layer — build in Android Studio.
 */
@Composable
fun MainTabs(
    engine: InferenceEngine,
    model: ModelEntry,
    conversations: ConversationPersistence,
    onSelectModel: (ModelEntry) -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    // "Deep thinking" preference — off by default (fast, direct replies). Mirrored onto the real engine so
    // the generation path reads it; a no-op for the mock/scripted engines.
    var deepThinking by remember { mutableStateOf((engine as? LlamaEngine)?.enableThinking ?: false) }
    LaunchedEffect(deepThinking) { (engine as? LlamaEngine)?.enableThinking = deepThinking }
    Scaffold(
        bottomBar = {
            // A custom bar instead of Material's NavigationBar: its content band is a hard-coded 80dp
            // (too tall vs WhatsApp's ~56dp), and it merges the system-nav inset INTO that height, so
            // shrinking the total via a height() modifier just crushes the icons. Here the content is a
            // fixed 56dp band and navigationBarsPadding() adds the system-nav inset BELOW it — tight
            // like a messaging app, and correct on gesture- and 3-button-nav devices alike.
            // M3 NavigationBar look (tonal container, no drop shadow) on the compact 60dp band.
            Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
                Row(
                    Modifier.fillMaxWidth().navigationBarsPadding().height(60.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BottomTab(NavKind.Chat, stringResource(R.string.tab_chat), tab == 0, { tab = 0 }, Modifier.weight(1f))
                    BottomTab(NavKind.Agent, stringResource(R.string.tab_agent), tab == 1, { tab = 1 }, Modifier.weight(1f))
                    BottomTab(NavKind.Settings, stringResource(R.string.tab_settings), tab == 2, { tab = 2 }, Modifier.weight(1f))
                }
            }
        },
    ) { pad ->
        // consumeWindowInsets(pad): the Scaffold reserves the bottom-nav height in `pad`, and a child
        // that also applies imePadding() would otherwise STACK the two — leaving the composer floating
        // one nav-bar-height above the keyboard (the "input in the middle" bug). Consuming `pad` here
        // means a descendant imePadding() computes `ime − navBar`, so the composer docks right onto the
        // keyboard when it's open and sits above the nav bar when it's closed.
        Box(Modifier.fillMaxSize().padding(pad).consumeWindowInsets(pad)) {
            // Keep all three tabs composed (alpha-hidden, not torn down) instead of a single-slot
            // `when`, so a rememberCoroutineScope()-launched send/run in Chat or Agent survives a
            // tab switch — matching iOS's TabView, which keeps every tab's Task-launched work alive.
            // The hidden tabs are also removed from touch/a11y focus so they can't intercept input
            // while invisible underneath the active one.
            Box(Modifier.fillMaxSize().tabVisibility(tab == 0)) {
                ChatTab(
                    engine = engine,
                    model = model,
                    persistence = conversations,
                    onSelectModel = onSelectModel,
                    deepThinking = deepThinking,
                    onDeepThinkingChange = { deepThinking = it },
                )
            }
            Box(Modifier.fillMaxSize().tabVisibility(tab == 1)) {
                // EchoTool deliberately not shipped (dev/demo tool — weak models grab it as a scratchpad
                // and burn mission steps on it; live-caught on the Mac twin).
                AgentScreen(engine = engine, tools = listOf(CalculatorTool(), UnitConverterTool(), DateCalcTool()))
            }
            Box(Modifier.fillMaxSize().tabVisibility(tab == 2)) {
                SettingsScreen(
                    model = model,
                    persistence = conversations,
                    onSelectModel = onSelectModel,
                    deepThinking = deepThinking,
                    onDeepThinkingChange = { deepThinking = it },
                )
            }
        }
    }
}

/**
 * The Chat tab: a WhatsApp-style two-level flow. Owns the [ConversationCoordinator] (and its live
 * `summaries`), and switches between the conversation LIST and an open CONVERSATION. Keeping the
 * coordinator here — above the list/conversation swap — means both views share one source of truth and
 * survive the swap.
 *
 * Conversation switch during a streaming reply: every lifecycle op below funnels through the
 * coordinator, which [ChatModel.stopGenerating]s the in-flight send (bump the generation id + cancel the
 * native decode) BEFORE it reads/mutates the transcript — so tokens from the outgoing chat can't bleed
 * into (or be persisted onto) the one being opened, and a captured index can't go out of bounds
 * (Q-004/Q-168). The partial already streamed is persisted as-is on the way out.
 */
@Composable
private fun ChatTab(
    engine: InferenceEngine,
    model: ModelEntry,
    persistence: ConversationPersistence,
    onSelectModel: (ModelEntry) -> Unit,
    deepThinking: Boolean,
    onDeepThinkingChange: (Boolean) -> Unit,
) {
    val coordinator = remember { ConversationCoordinator(ChatModel(engine), persistence) }
    var summaries by remember { mutableStateOf(coordinator.summaries) }
    var inConversation by remember { mutableStateOf(false) }
    LaunchedEffect(coordinator) { coordinator.onChange = { summaries = it } }

    if (inConversation) {
        ChatScreen(
            coordinator = coordinator,
            model = model,
            onBack = { coordinator.persist(); inConversation = false },
            onSelectModel = onSelectModel,
            deepThinking = deepThinking,
            onDeepThinkingChange = onDeepThinkingChange,
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
    .clickable(
        enabled = !visible,
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
    ) {}

private enum class NavKind { Chat, Agent, Settings }

/**
 * One bottom-bar destination in the native Material 3 NavigationBar idiom: the icon sits in a
 * PILL indicator (secondaryContainer when selected, transparent otherwise — colour-only change,
 * geometry never moves), label below. No-ripple click keeps the band calm like the platform bar.
 * [modifier] carries the RowScope weight so the three tabs split the width evenly.
 */
@Composable
private fun BottomTab(
    kind: NavKind,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val labelColor = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
    val pill by animateColorAsState(
        if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0f),
        label = "tabPill",
    )
    Column(
        modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier
                .width(56.dp)
                .height(30.dp)
                .background(pill, RoundedCornerShape(15.dp)),
            contentAlignment = Alignment.Center,
        ) {
            NavIcon(kind, selected)
        }
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = labelColor,
            maxLines = 1,                       // never wrap past the fixed 60dp band at large font scale
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 3.dp),
        )
    }
}

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
