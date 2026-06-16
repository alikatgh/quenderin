package ai.quenderin.app.ui

import ai.quenderin.core.ChatMessage
import ai.quenderin.core.ChatModel
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.Role
import ai.quenderin.core.SupportContact
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
 * M2 chat over [ChatModel]. Maps the core listener into Compose state and runs the
 * blocking `send` on IO. With the real [ai.quenderin.core.LlamaEngine] this swaps to
 * its streaming overload for token-by-token rendering. Twin of iOS `ChatView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(engine: InferenceEngine, model: ModelEntry) {
    val scope = rememberCoroutineScope()
    var messages by remember { mutableStateOf<List<ChatMessage>>(emptyList()) }
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val chat = remember { ChatModel(engine).apply { onChange = { messages = it } } }
    val context = LocalContext.current

    Scaffold(topBar = { TopAppBar(title = { Text(model.label) }) }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad)) {
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(messages) { msg ->
                    MessageBubble(msg) {
                        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse(SupportContact.reportMailtoUri(msg.text, "chat")))
                        runCatching { context.startActivity(intent) }
                    }
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
                    value = input,
                    onValueChange = { input = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Message") },
                    enabled = !busy,
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    enabled = !busy && input.isNotBlank(),
                    onClick = {
                        val text = input.trim()
                        input = ""
                        scope.launch(Dispatchers.IO) {
                            busy = true
                            try {
                                chat.send(text)
                            } catch (_: Throwable) {
                                // Surfaced in a fuller UI; swallowed here to keep the shell minimal.
                            } finally {
                                busy = false
                            }
                        }
                    },
                ) { Text("Send") }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(msg: ChatMessage, onReport: () -> Unit = {}) {
    val mine = msg.role == Role.USER
    val reportable = !mine && msg.text.isNotBlank()
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            color = if (mine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
            shape = RoundedCornerShape(14.dp),
            // Long-press an AI response to report it (Generative-AI flag mechanism).
            modifier = if (reportable) Modifier.combinedClickable(onClick = {}, onLongClick = onReport) else Modifier,
        ) {
            Text(
                text = msg.text,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                color = if (mine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
