package ai.quenderin.app.ui

import ai.quenderin.core.CalculatorTool
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.DateCalcTool
import ai.quenderin.core.EchoTool
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.UnitConverterTool
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.zIndex

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
            NavigationBar {
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { tab = 0 },
                    icon = { Text("💬", modifier = Modifier.clearAndSetSemantics {}) },
                    label = { Text("Chat") },
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { tab = 1 },
                    icon = { Text("🤖", modifier = Modifier.clearAndSetSemantics {}) },
                    label = { Text("Agent") },
                )
                NavigationBarItem(
                    selected = tab == 2,
                    onClick = { tab = 2 },
                    icon = { Text("⚙️", modifier = Modifier.clearAndSetSemantics {}) },
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
