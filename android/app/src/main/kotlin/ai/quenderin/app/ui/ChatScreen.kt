@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package ai.quenderin.app.ui

import ai.quenderin.core.ChatMessage
import ai.quenderin.core.ConversationExporter
import ai.quenderin.core.ChatModel
import ai.quenderin.core.ConversationCoordinator
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.ConversationSummary
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.Role
import ai.quenderin.core.SupportContact
import ai.quenderin.core.isFlagged
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * The chat surface. A polished, cohesive layout (avatar top bar with a live status line, message
 * bubbles with speaker-side tails, a typing indicator, and a pill composer) built on the shared
 * [QuenderinTheme] design tokens. Maps the pure [ChatModel] listener into Compose state and runs the
 * blocking [InferenceEngine.complete] off the main thread. Twin of iOS `ChatView`.
 */
@Composable
fun ChatScreen(
    engine: InferenceEngine,
    model: ModelEntry,
    persistence: ConversationPersistence,
    onSelectModel: (ModelEntry) -> Unit = {},
    deepThinking: Boolean = false,
    onDeepThinkingChange: (Boolean) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    var messages by remember { mutableStateOf<List<ChatMessage>>(emptyList()) }
    var summaries by remember { mutableStateOf<List<ConversationSummary>>(emptyList()) }
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    // Tapping the top-bar name/avatar opens the model "profile" sheet; from there the user can open
    // the model picker to switch models (same picker Settings uses).
    var showProfile by remember { mutableStateOf(false) }
    var showPicker by remember { mutableStateOf(false) }
    // A failed generation must be VISIBLE, not silently swallowed: a swallowed throw (engine not
    // loaded, native decode error) looks identical to "the app is ignoring me". Surface + log it.
    var sendError by remember { mutableStateOf<String?>(null) }
    val coordinator = remember { ConversationCoordinator(ChatModel(engine), persistence) }
    val chat = coordinator.chat
    LaunchedEffect(coordinator) {
        messages = chat.messages
        summaries = coordinator.summaries
        chat.onChange = { messages = it }
        coordinator.onChange = { summaries = it }
    }
    val context = LocalContext.current
    val listState = rememberLazyListState()
    // Keep the newest message in view as the transcript grows / a reply streams in.
    LaunchedEffect(messages.size, busy) {
        val count = messages.size + if (busy) 1 else 0
        if (count > 0) listState.animateScrollToItem(count - 1)
    }

    // imePadding() lifts the whole chat (and its composer) above the soft keyboard. Needed because
    // targetSdk 35 forces edge-to-edge on Android 15+, which makes the manifest's `adjustResize` a no-op —
    // without this the keyboard draws OVER the input field and you can't see what you're typing.
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).imePadding()) {
        ChatTopBar(
            model = model,
            hasMessages = messages.isNotEmpty(),
            onTitleClick = { showProfile = true },
            onHistory = { showHistory = true },
            onNew = { coordinator.startNew() },
            onShare = {
                val md = ConversationExporter.markdown(messages, model.label)
                val share = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, "Quenderin conversation")
                    putExtra(Intent.EXTRA_TEXT, md)
                }
                runCatching { context.startActivity(Intent.createChooser(share, "Share conversation")) }
            },
        )

        if (messages.isEmpty() && !busy) {
            EmptyState(model, Modifier.weight(1f))
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 12.dp),
            ) {
                item { DayDivider("Today") }
                items(messages) { msg ->
                    MessageBubble(msg) {
                        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse(SupportContact.reportMailtoUri(msg.text, "chat")))
                        runCatching { context.startActivity(intent) }
                    }
                }
                if (busy) item { TypingBubble() }
            }
        }

        // A failed generation is shown here instead of being silently dropped.
        sendError?.let { err ->
            Text(
                "⚠️ Couldn't generate a reply: $err",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp)
                    .semantics { contentDescription = "Generation error: $err" },
            )
        }

        Text(
            SupportContact.AI_DISCLAIMER,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )

        Composer(
            input = input,
            enabled = !busy,
            onInput = { input = it },
            onSend = {
                val text = input.trim()
                if (text.isEmpty()) return@Composer
                input = ""
                // Flip busy synchronously on the main thread so a rapid double-tap can't enqueue a
                // second send before IO flips the flag.
                busy = true
                sendError = null
                scope.launch(Dispatchers.IO) {
                    try {
                        chat.send(text)
                    } catch (t: Throwable) {
                        // Do NOT swallow: surface + log the reason. A silent catch makes a real
                        // failure indistinguishable from the app ignoring the message.
                        Log.e("Quenderin", "chat.send failed", t)
                        sendError = t.message?.takeIf { it.isNotBlank() }
                            ?: "${t.javaClass.simpleName}: generation failed"
                    } finally {
                        coordinator.persist()
                        busy = false
                    }
                }
            },
        )
    }

    if (showHistory) {
        ModalBottomSheet(onDismissRequest = { showHistory = false }) {
            ConversationHistoryList(
                summaries = summaries,
                onOpen = { id -> coordinator.open(id); showHistory = false },
                onDelete = { id -> coordinator.delete(id) },
                onClearAll = { coordinator.clearAll(); showHistory = false },
            )
        }
    }

    if (showProfile) {
        ModalBottomSheet(onDismissRequest = { showProfile = false }) {
            ModelProfileSheet(
                model = model,
                deepThinking = deepThinking,
                onDeepThinkingChange = onDeepThinkingChange,
                onChangeModel = { showProfile = false; showPicker = true },
            )
        }
    }

    if (showPicker) {
        ModalBottomSheet(onDismissRequest = { showPicker = false }) {
            ModelPickerSheet(
                currentModelId = model.id,
                onSelect = { picked ->
                    showPicker = false
                    if (picked.id != model.id) onSelectModel(picked)
                },
            )
        }
    }
}

// ── Top bar: avatar + name + live "on-device · private" status + overflow menu ──
@Composable
private fun ChatTopBar(
    model: ModelEntry,
    hasMessages: Boolean,
    onTitleClick: () -> Unit,
    onHistory: () -> Unit,
    onNew: () -> Unit,
    onShare: () -> Unit,
) {
    val colors = Quenderin.colors
    Surface(color = MaterialTheme.colorScheme.surface, shadowElevation = 2.dp) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The avatar + name is a tappable "contact" that opens the model profile (like tapping a
            // chat's header in WhatsApp). Ripple + a11y label so it reads as a button.
            Row(
                Modifier
                    .weight(1f)
                    .combinedClickable(
                        onClick = onTitleClick,
                        onLongClick = {},
                    )
                    .semantics { contentDescription = "About ${model.label}" }
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ModelAvatar(size = 40.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        model.label,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).background(colors.status, CircleShape))
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "on-device · private",
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.statusText,
                        )
                    }
                }
            }
            var menuOpen by remember { mutableStateOf(false) }
            Box {
                Box(
                    Modifier
                        .size(40.dp)
                        .semantics { contentDescription = "More options" }
                        .combinedClickable(onClick = { menuOpen = true }, onLongClick = {}),
                    contentAlignment = Alignment.Center,
                ) { OverflowIcon(MaterialTheme.colorScheme.onSurfaceVariant) }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(text = { Text("History") }, onClick = { menuOpen = false; onHistory() })
                    DropdownMenuItem(text = { Text("New conversation") }, onClick = { menuOpen = false; onNew() })
                    if (hasMessages) {
                        DropdownMenuItem(text = { Text("Share") }, onClick = { menuOpen = false; onShare() })
                    }
                }
            }
        }
    }
}

/** The model rendered as a chat "contact": a gradient orb with a monogram. */
@Composable
internal fun ModelAvatar(size: androidx.compose.ui.unit.Dp) {
    Box(
        Modifier
            .size(size)
            .background(
                Brush.radialGradient(listOf(Color(0xFF8A82E6), Color(0xFF4F46B8))),
                CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text("Q", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.42f).sp)
    }
}

// ── Message bubble with a speaker-side tail + flagged-output safeguard ──
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(msg: ChatMessage, onReport: () -> Unit = {}) {
    val mine = msg.role == Role.USER
    val colors = Quenderin.colors
    val reportable = !mine && msg.text.isNotBlank()
    Column(
        Modifier
            .fillMaxWidth()
            .then(if (msg.isFlagged) Modifier.semantics(mergeDescendants = true) {} else Modifier)
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
        ) {
            Surface(
                color = if (mine) colors.userBubble else colors.assistantBubble,
                shape = if (mine) QuenderinShapes.userBubble else QuenderinShapes.assistantBubble,
                modifier = Modifier
                    .widthIn(max = 300.dp)
                    .then(
                        if (reportable)
                            Modifier
                                .combinedClickable(onClick = {}, onLongClick = onReport)
                                .semantics {
                                    customActions = listOf(
                                        CustomAccessibilityAction("Report this response") { onReport(); true }
                                    )
                                }
                        else Modifier,
                    ),
            ) {
                if (mine) {
                    // The user's own message is shown literally (what they typed), not re-interpreted.
                    Text(
                        text = msg.text,
                        modifier = Modifier.padding(horizontal = 13.dp, vertical = 9.dp),
                        color = colors.onUserBubble,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                } else {
                    // Assistant replies are Markdown — render bold/headings/lists/code instead of raw markers.
                    MarkdownText(
                        text = msg.text,
                        color = colors.onAssistantBubble,
                        modifier = Modifier.padding(horizontal = 13.dp, vertical = 9.dp),
                    )
                }
            }
        }
        if (msg.isFlagged) {
            Text(
                SupportContact.FLAGGED_OUTPUT_NOTICE,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.fillMaxWidth().padding(top = 2.dp, start = 4.dp),
            )
        }
    }
}

/** Assistant-side "…" while a reply is being generated. */
@Composable
private fun TypingBubble() {
    val colors = Quenderin.colors
    val t = rememberInfiniteTransition(label = "typing")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Surface(color = colors.assistantBubble, shape = QuenderinShapes.assistantBubble) {
            Row(
                Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                for (i in 0 until 3) {
                    val a by t.animateFloat(
                        initialValue = 0.3f, targetValue = 1f,
                        animationSpec = infiniteRepeatable(
                            tween(600, delayMillis = i * 160), RepeatMode.Reverse,
                        ),
                        label = "dot$i",
                    )
                    Box(Modifier.size(7.dp).background(colors.assistantTimestamp.copy(alpha = a), CircleShape))
                }
            }
        }
    }
}

@Composable
private fun DayDivider(text: String) {
    val colors = Quenderin.colors
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Surface(color = colors.dayDivider, shape = CircleShape) {
            Text(
                text,
                style = MaterialTheme.typography.labelSmall,
                color = colors.onDayDivider,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun EmptyState(model: ModelEntry, modifier: Modifier) {
    Column(
        modifier.fillMaxWidth().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        ModelAvatar(size = 72.dp)
        Spacer(Modifier.height(16.dp))
        Text(
            "Ask ${model.label} anything",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Runs entirely on your phone. Nothing you type leaves the device.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.widthIn(max = 280.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}

// ── Composer: pill text field + circular send button ──
@Composable
private fun Composer(
    input: String,
    enabled: Boolean,
    onInput: (String) -> Unit,
    onSend: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 10.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = QuenderinShapes.pill,
            modifier = Modifier.weight(1f),
        ) {
            Box(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                if (input.isEmpty()) {
                    Text(
                        "Message",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                BasicTextField(
                    value = input,
                    onValueChange = onInput,
                    enabled = enabled,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        val canSend = enabled && input.isNotBlank()
        Box(
            Modifier
                .size(48.dp)
                .background(
                    if (canSend) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.primary.copy(alpha = 0.4f),
                    CircleShape,
                )
                .semantics { contentDescription = "Send message" }
                .combinedClickable(enabled = canSend, onClick = onSend, onLongClick = {}),
            contentAlignment = Alignment.Center,
        ) { SendIcon(MaterialTheme.colorScheme.onPrimary) }
    }
}

// ── Canvas icons (no icon-font dependency) ──
@Composable
private fun SendIcon(color: Color) {
    androidx.compose.foundation.Canvas(Modifier.size(22.dp)) {
        val w = size.width; val h = size.height; val cx = w / 2f
        val sw = 2.4.dp.toPx()
        drawLine(color, androidx.compose.ui.geometry.Offset(cx, h * 0.80f), androidx.compose.ui.geometry.Offset(cx, h * 0.24f), sw, StrokeCap.Round)
        drawLine(color, androidx.compose.ui.geometry.Offset(cx, h * 0.22f), androidx.compose.ui.geometry.Offset(w * 0.28f, h * 0.48f), sw, StrokeCap.Round)
        drawLine(color, androidx.compose.ui.geometry.Offset(cx, h * 0.22f), androidx.compose.ui.geometry.Offset(w * 0.72f, h * 0.48f), sw, StrokeCap.Round)
    }
}

@Composable
private fun OverflowIcon(color: Color) {
    androidx.compose.foundation.Canvas(Modifier.size(22.dp)) {
        val cx = size.width / 2f
        val r = 1.9.dp.toPx()
        for (fy in listOf(0.26f, 0.5f, 0.74f)) {
            drawCircle(color, r, androidx.compose.ui.geometry.Offset(cx, size.height * fy))
        }
    }
}

/** The chat-history sheet: tap a row to open that conversation, Delete to remove it. */
@Composable
private fun ConversationHistoryList(
    summaries: List<ConversationSummary>,
    onOpen: (String) -> Unit,
    onDelete: (String) -> Unit,
    onClearAll: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("History", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            if (summaries.isNotEmpty()) {
                Text(
                    "Clear all",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier
                        .combinedClickable(onClick = onClearAll, onLongClick = {})
                        .padding(8.dp),
                )
            }
        }
        if (summaries.isEmpty()) {
            Text(
                "No conversations yet",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
        } else {
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                items(summaries) { summary ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .combinedClickable(onClick = { onOpen(summary.id) }, onLongClick = {})
                            .padding(horizontal = 20.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(summary.title, modifier = Modifier.weight(1f), maxLines = 1, color = MaterialTheme.colorScheme.onSurface)
                        Text(
                            "Delete",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier
                                .combinedClickable(onClick = { onDelete(summary.id) }, onLongClick = {})
                                .padding(8.dp),
                        )
                    }
                }
            }
        }
    }
}
