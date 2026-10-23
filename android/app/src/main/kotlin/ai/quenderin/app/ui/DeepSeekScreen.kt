package ai.quenderin.app.ui

import ai.quenderin.app.DeepSeekController
import ai.quenderin.core.DeepSeekCatalog
import ai.quenderin.core.ProviderRole
import ai.quenderin.core.ReasoningEffort
import android.app.Activity
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.EditText
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** Real cloud destination, with its own consent and journal. No local conversation enters this UI. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeepSeekScreen(controller: DeepSeekController, onBack: () -> Unit) {
    val state by controller.state.collectAsState()
    var key by remember { mutableStateOf("") } // Deliberately never saveable or placed in an Activity Bundle.
    var editKey by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var consent by remember { mutableStateOf(false) }
    var history by remember { mutableStateOf(false) }
    var modelMenu by remember { mutableStateOf(false) }
    var effortMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    DisposableEffect(context) {
        val window = (context as? Activity)?.window
        val wasSecure = window?.attributes?.flags?.and(WindowManager.LayoutParams.FLAG_SECURE) != 0
        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose {
            key = ""
            if (!wasSecure) window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
    val leave = { key = ""; controller.stop(); onBack() }
    BackHandler(onBack = leave)
    LaunchedEffect(state.currentID) { draft = "" }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("DeepSeek") }, navigationIcon = {
                TextButton(onClick = leave) { Text("Back") }
            }, actions = {
                Box {
                    TextButton(onClick = { history = true }, enabled = !state.busy && state.threads.isNotEmpty()) { Text("History") }
                    DropdownMenu(history, onDismissRequest = { history = false }) {
                        state.threads.forEach { thread ->
                            DropdownMenuItem(text = { Text(thread.title, maxLines = 2) }, onClick = {
                                history = false; controller.openConversation(thread.id)
                            })
                        }
                    }
                }
            })
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Text("Cloud · api.deepseek.com", style = MaterialTheme.typography.labelLarge)
                Text("Text chat goes directly to DeepSeek using your API account. Tools are disabled; on-device files and local chats stay separate.",
                    style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box {
                        TextButton(onClick = { modelMenu = true }, enabled = !state.busy && state.rows.isEmpty()) { Text(state.model) }
                        DropdownMenu(modelMenu, onDismissRequest = { modelMenu = false }) {
                            DeepSeekCatalog.models.forEach { model ->
                                DropdownMenuItem(text = { Text(model) }, onClick = { modelMenu = false; controller.selectModel(model) })
                            }
                        }
                    }
                    Box {
                        TextButton(onClick = { effortMenu = true }, enabled = !state.busy) { Text("Thinking: ${state.effort.wire}") }
                        DropdownMenu(effortMenu, onDismissRequest = { effortMenu = false }) {
                            ReasoningEffort.entries.forEach { effort ->
                                DropdownMenuItem(text = { Text(effort.wire.replaceFirstChar(Char::uppercaseChar)) },
                                    onClick = { effortMenu = false; controller.selectEffort(effort) })
                            }
                        }
                    }
                }
            }
            if (!state.ready) {
                if (state.message == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(state.message ?: "Opening saved cloud conversations…", Modifier.padding(16.dp))
            } else if (!state.connected || editKey) {
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Connect your DeepSeek account", style = MaterialTheme.typography.titleLarge)
                    Text("Your key is encrypted with Android Keystore on this device. Connect checks available models without sending a paid chat request. Each message can incur DeepSeek charges. App limits do not cap your provider invoice.")
                    SecureApiKeyField(key, onChange = { key = it }, enabled = !state.busy)
                    Button(onClick = {
                        val owned = key.toCharArray(); key = ""; editKey = false; controller.connect(owned)
                    }, enabled = key.isNotBlank() && !state.busy) { Text(if (state.busy) "Checking models…" else "Connect securely") }
                    if (state.connected) TextButton(onClick = { key = ""; editKey = false }, enabled = !state.busy) { Text("Cancel") }
                    TextButton(onClick = { key = ""; controller.removeKey() }, enabled = !state.busy) { Text("Remove saved API keys") }
                    Text("Removing keys clears DeepSeek credentials on this device and keeps saved conversations.", style = MaterialTheme.typography.bodySmall)
                    state.message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            } else {
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = { consent = true }, enabled = !state.busy) { Text("New cloud chat") }
                    TextButton(onClick = { editKey = true }, enabled = !state.busy) { Text("Change key") }
                    TextButton(onClick = controller::removeKey, enabled = !state.busy) { Text("Remove key") }
                }
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (state.currentID == null) item {
                        Text("Start a new cloud chat to continue. Existing local conversations are never uploaded.", style = MaterialTheme.typography.bodyLarge)
                    }
                    itemsIndexed(state.rows) { _, row ->
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(if (row.role == ProviderRole.USER) "You" else "DeepSeek", style = MaterialTheme.typography.labelLarge)
                            row.reasoning?.takeIf { it.isNotEmpty() }?.let { ReasoningText(it) }
                            Text(row.text, style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                    if (state.partial.isNotEmpty() || state.partialReasoning.isNotEmpty() || state.streaming) item {
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(if (state.streaming) "DeepSeek · replying" else "Incomplete reply", style = MaterialTheme.typography.labelLarge)
                            if (state.partialReasoning.isNotEmpty()) ReasoningText(state.partialReasoning)
                            Text(state.partial.ifEmpty { "Thinking…" })
                        }
                    }
                    state.usage?.let { usage -> item {
                        Text("Usage: ${usage.inputTokens} input · ${usage.outputTokens} output tokens", style = MaterialTheme.typography.labelMedium)
                    } }
                    state.message?.let { message -> item { Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
                    if (state.incomplete && !state.streaming) item {
                        Text("Saved as interrupted. Start a new cloud chat to send again.", style = MaterialTheme.typography.bodySmall)
                    }
                }
                if (state.streaming) {
                    Button(onClick = controller::stop, modifier = Modifier.fillMaxWidth().padding(16.dp)) { Text("Stop reply") }
                } else if (state.currentID != null && !state.incomplete) {
                    Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(value = draft, onValueChange = { if (it.toByteArray().size <= 1_048_576) draft = it },
                            label = { Text("Message DeepSeek") }, modifier = Modifier.weight(1f), maxLines = 5, enabled = !state.busy)
                        Button(onClick = { val text = draft; draft = ""; controller.send(text) }, enabled = draft.isNotBlank() && !state.busy) { Text("Send") }
                    }
                }
            }
        }
    }
    if (consent) AlertDialog(onDismissRequest = { consent = false }, title = { Text("New conversation with DeepSeek") },
        text = { Text("Messages and DeepSeek replies in this new conversation will be sent to api.deepseek.com when you tap Send. Your local chats and files are excluded. Tools are disabled. DeepSeek can charge your account; Quenderin sends at most one request per action and never retries automatically.") },
        confirmButton = { TextButton(onClick = { consent = false; controller.newConversation(consented = true) }) { Text("Create cloud chat") } },
        dismissButton = { TextButton(onClick = { consent = false }) { Text("Cancel") } })
}

/** Native password editor explicitly prevents OS state/autofill/content-capture and keyboard learning.
 * The editor's value is owned only by this screen's ordinary remember state, never saveable state. */
@Composable private fun SecureApiKeyField(value: String, onChange: (String) -> Unit, enabled: Boolean) {
    var editor by remember { mutableStateOf<EditText?>(null) }
    val latestChange by rememberUpdatedState(onChange)
    val textColor = MaterialTheme.colorScheme.onSurface
    val hintColor = MaterialTheme.colorScheme.onSurfaceVariant
    DisposableEffect(Unit) { onDispose { editor?.text?.clear(); editor = null } }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("DeepSeek API key", style = MaterialTheme.typography.labelLarge)
        AndroidView(modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp), factory = { context ->
            EditText(context).apply {
                editor = this
                hint = "API key"
                isSingleLine = true
                isSaveEnabled = false
                isSaveFromParentEnabled = false
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                if (android.os.Build.VERSION.SDK_INT >= 29) importantForContentCapture = View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_DONE
                filters = arrayOf(android.text.InputFilter.LengthFilter(256))
                addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { latestChange(s?.toString() ?: "") }
                    override fun afterTextChanged(s: Editable?) {}
                })
            }
        }, update = { view ->
            view.isEnabled = enabled
            view.setTextColor(android.graphics.Color.argb((textColor.alpha * 255).toInt(), (textColor.red * 255).toInt(), (textColor.green * 255).toInt(), (textColor.blue * 255).toInt()))
            view.setHintTextColor(android.graphics.Color.argb((hintColor.alpha * 255).toInt(), (hintColor.red * 255).toInt(), (hintColor.green * 255).toInt(), (hintColor.blue * 255).toInt()))
            if (view.text.toString() != value) { view.setText(value); view.setSelection(value.length) }
        })
    }
}

@Composable private fun ReasoningText(text: String) {
    var expanded by remember { mutableStateOf(false) }
    TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) { Text(if (expanded) "Hide thinking" else "Show thinking") }
    if (expanded) Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
