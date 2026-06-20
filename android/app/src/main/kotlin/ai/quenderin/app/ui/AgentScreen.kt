package ai.quenderin.app.ui

import ai.quenderin.core.AgentDecision
import ai.quenderin.core.AgentRun
import ai.quenderin.core.AgentSession
import ai.quenderin.core.AgentStep
import ai.quenderin.core.AgentTool
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.SupportContact
import ai.quenderin.core.userMessage
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * M4's screen: give the agent a goal and watch it plan → use tools → answer. Compose twin
 * of iOS `AgentView`, bound to [AgentSession] (which streams steps live via onChange).
 * Built on the mock engine; reachable from the app's navigation. Needs Android Studio to
 * build (the app/cliff layer) — the AgentSession brain underneath is kotlinc-verified.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun AgentScreen(engine: InferenceEngine, tools: List<AgentTool>) {
    val scope = rememberCoroutineScope()
    var steps by remember { mutableStateOf<List<AgentStep>>(emptyList()) }
    var answer by remember { mutableStateOf<String?>(null) }
    var running by remember { mutableStateOf(false) }
    var haltReason by remember { mutableStateOf<AgentRun.HaltReason?>(null) }
    var goal by remember { mutableStateOf("") }
    val session = remember {
        AgentSession(engine, tools).apply {
            onChange = {
                steps = this.steps
                answer = this.answer
                running = this.isRunning
                haltReason = this.haltReason
            }
        }
    }
    val context = LocalContext.current

    Scaffold(topBar = { TopAppBar(title = { Text("Agent") }) }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad)) {
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(steps) { step -> AgentStepRow(step) }
                answer?.let { a ->
                    item {
                        Surface(
                            color = MaterialTheme.colorScheme.primaryContainer,
                            shape = RoundedCornerShape(12.dp),
                            // Long-press the answer to report it (Generative-AI flag mechanism).
                            modifier = Modifier.combinedClickable(
                                onClick = {},
                                onLongClick = {
                                    val intent = Intent(Intent.ACTION_SENDTO, Uri.parse(SupportContact.reportMailtoUri(a, "agent")))
                                    runCatching { context.startActivity(intent) }
                                },
                            ),
                        ) {
                            Text(a, modifier = Modifier.padding(12.dp))
                        }
                    }
                }
                // The agent stopped without an answer (step limit, safety gate, plan error):
                // say so instead of trailing off into silence.
                if (answer == null && !running) {
                    haltReason?.userMessage?.let { msg -> item { AgentHaltBanner(msg) } }
                }
            }

            // AI-content disclaimer (Generative-AI content policy).
            Text(
                SupportContact.AI_DISCLAIMER,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            )

            Row(
                Modifier.fillMaxWidth().padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = goal,
                    onValueChange = { goal = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Give the agent a goal") },
                    enabled = !running,
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    enabled = !running && goal.isNotBlank(),
                    onClick = {
                        val g = goal.trim()
                        goal = ""
                        scope.launch(Dispatchers.IO) { session.run(g) }
                    },
                ) { Text("Run") }
            }
        }
    }
}

/**
 * Shown when the agent halts without an answer — turns a silent dead-end into an explanation
 * (step limit, safety gate, or plan error). Tinted distinctly from the answer. Compose twin
 * of iOS `AgentHaltBanner`.
 */
@Composable
private fun AgentHaltBanner(message: String) {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.Top) {
            Text("⚠️")
            Spacer(Modifier.width(8.dp))
            Text(message, color = MaterialTheme.colorScheme.onErrorContainer)
        }
    }
}

@Composable
private fun AgentStepRow(step: AgentStep) {
    Column(Modifier.fillMaxWidth()) {
        (step.decision as? AgentDecision.UseTool)?.let { tool ->
            Text(
                "${tool.name}(${tool.input})",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        step.observation?.let { obs ->
            Text(
                "→ $obs",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
