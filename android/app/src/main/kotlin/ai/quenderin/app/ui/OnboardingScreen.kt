package ai.quenderin.app.ui

import ai.quenderin.core.AndroidDeviceProfile
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelDownloader
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelSelection
import ai.quenderin.core.OnboardingModel
import ai.quenderin.core.OnboardingPhase
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Top-level router: drives [OnboardingModel] until it reaches Ready, then hands off to
 * [ChatScreen]. Maps the core's listener (`onChange`) into Compose state and runs the
 * blocking download/load on [Dispatchers.IO]. Twin of iOS `RootView`.
 */
@Composable
fun AppRoot(engine: InferenceEngine, downloader: ModelDownloader, probe: () -> AndroidDeviceProfile) {
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf<OnboardingPhase>(OnboardingPhase.Idle) }
    val onboarding = remember {
        OnboardingModel(engine, downloader).apply { onChange = { phase = it } }
    }

    when (val current = phase) {
        is OnboardingPhase.Ready -> MainTabs(engine = engine, model = current.model)
        else -> OnboardingScreen(
            phase = current,
            selection = onboarding.selection,
            onStart = { onboarding.start(probe()) },   // world-class selector path
            onAccept = { model -> scope.launch(Dispatchers.IO) { onboarding.acceptAndPrepare(model) } },
        )
    }
}

@Composable
fun OnboardingScreen(
    phase: OnboardingPhase,
    selection: ModelSelection?,
    onStart: () -> Unit,
    onAccept: (ModelEntry) -> Unit,
) {
    Surface(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("Quenderin", style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.height(8.dp))
            Text(
                "An AI that runs on your phone — even offline.",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(32.dp))

            when (phase) {
                is OnboardingPhase.Idle ->
                    Button(onClick = onStart) { Text("Get started") }

                is OnboardingPhase.Probing ->
                    CircularProgressIndicator()

                is OnboardingPhase.Recommended -> {
                    Text("Recommended for your device", style = MaterialTheme.typography.labelLarge)
                    Spacer(Modifier.height(4.dp))
                    Text(phase.model.label, style = MaterialTheme.typography.titleMedium)
                    Text(phase.model.sizeLabel, style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        phase.fitness.message,   // = the selector's rationale
                        style = MaterialTheme.typography.bodySmall,
                        textAlign = TextAlign.Center,
                    )
                    selection?.let { sel ->
                        Spacer(Modifier.height(8.dp))
                        Text(
                            sel.thermalBattery.chatVerdict,
                            style = MaterialTheme.typography.bodySmall,
                            textAlign = TextAlign.Center,
                        )
                        Text(
                            sel.thermalBattery.sustainedVerdict,
                            style = MaterialTheme.typography.bodySmall,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = { onAccept(phase.model) }) { Text("Download & continue") }
                }

                is OnboardingPhase.Downloading -> {
                    Text("Downloading ${phase.model.label}…")
                    Spacer(Modifier.height(12.dp))
                    LinearProgressIndicator(
                        progress = { phase.fraction.toFloat() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text("${(phase.fraction * 100).toInt()}%")
                }

                is OnboardingPhase.Loading -> {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(8.dp))
                    Text("Loading ${phase.model.label}…")
                }

                is OnboardingPhase.Ready ->
                    Text("Ready.") // AppRoot has already switched to ChatScreen

                is OnboardingPhase.Failed -> {
                    Text("Couldn't get set up", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        phase.reason,
                        style = MaterialTheme.typography.bodySmall,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = onStart) { Text("Try again") }
                }
            }
        }
    }
}
