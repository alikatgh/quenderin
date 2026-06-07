package ai.quenderin.app.ui

import ai.quenderin.core.CalculatorTool
import ai.quenderin.core.EchoTool
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelEntry
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

/**
 * The post-onboarding shell: Chat + Agent tabs sharing the loaded model/engine. The Compose
 * twin of iOS `RootView`'s TabView. Emoji icons keep this free of the material-icons-extended
 * dependency. App/cliff layer — build in Android Studio.
 */
@Composable
fun MainTabs(engine: InferenceEngine, model: ModelEntry) {
    var tab by remember { mutableIntStateOf(0) }
    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { tab = 0 },
                    icon = { Text("💬") },
                    label = { Text("Chat") },
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { tab = 1 },
                    icon = { Text("🤖") },
                    label = { Text("Agent") },
                )
            }
        },
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(pad)) {
            when (tab) {
                0 -> ChatScreen(engine = engine, model = model)
                else -> AgentScreen(engine = engine, tools = listOf(CalculatorTool(), EchoTool()))
            }
        }
    }
}
