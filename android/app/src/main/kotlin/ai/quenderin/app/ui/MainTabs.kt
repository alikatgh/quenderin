package ai.quenderin.app.ui

import ai.quenderin.core.CalculatorTool
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.DateCalcTool
import ai.quenderin.core.EchoTool
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.UnitConverterTool
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
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
    Scaffold(
        bottomBar = {
            NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                val itemColors = NavigationBarItemDefaults.colors(
                    indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                    selectedTextColor = MaterialTheme.colorScheme.primary,
                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { tab = 0 },
                    colors = itemColors,
                    icon = { NavIcon(NavKind.Chat, tab == 0) },
                    label = { Text("Chat") },
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { tab = 1 },
                    colors = itemColors,
                    icon = { NavIcon(NavKind.Agent, tab == 1) },
                    label = { Text("Agent") },
                )
                NavigationBarItem(
                    selected = tab == 2,
                    onClick = { tab = 2 },
                    colors = itemColors,
                    icon = { NavIcon(NavKind.Settings, tab == 2) },
                    label = { Text("Settings") },
                )
            }
        },
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(pad)) {
            // Keep all three tabs composed (alpha-hidden, not torn down) instead of a single-slot
            // `when`, so a rememberCoroutineScope()-launched send/run in Chat or Agent survives a
            // tab switch — matching iOS's TabView, which keeps every tab's Task-launched work alive.
            // The hidden tabs are also removed from touch/a11y focus so they can't intercept input
            // while invisible underneath the active one.
            Box(Modifier.fillMaxSize().tabVisibility(tab == 0)) {
                ChatScreen(engine = engine, model = model, persistence = conversations)
            }
            Box(Modifier.fillMaxSize().tabVisibility(tab == 1)) {
                AgentScreen(engine = engine, tools = listOf(CalculatorTool(), UnitConverterTool(), DateCalcTool(), EchoTool()))
            }
            Box(Modifier.fillMaxSize().tabVisibility(tab == 2)) {
                SettingsScreen(model = model, persistence = conversations, onSelectModel = onSelectModel)
            }
        }
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
 * Crisp, theme-tinted line icons drawn in Compose — replacing the full-colour emoji that clashed with
 * the app's palette. Outline style, coloured by selection (primary when active, muted otherwise).
 */
@Composable
private fun NavIcon(kind: NavKind, selected: Boolean) {
    val color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
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
