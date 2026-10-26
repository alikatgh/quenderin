package ai.quenderin.app.ui

import ai.quenderin.app.RemoteHarnessController
import ai.quenderin.core.*
import android.content.ContextWrapper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** Native remote destination; it consumes only RemoteHarnessController state and events. */
@Composable
fun RemoteHarnessScreen(controller: RemoteHarnessController, onBack: () -> Unit) {
    val state = controller.state
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val lifecycle = remember(context) { generateSequence(context) { (it as? ContextWrapper)?.baseContext?.takeIf { parent -> parent !== it } }
        .filterIsInstance<LifecycleOwner>().firstOrNull()?.lifecycle }
    DisposableEffect(controller, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_START) controller.foreground() }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer) }
    }
    var more by remember { mutableStateOf(false) }
    var details by remember { mutableStateOf(false) }
    var presentation by remember { mutableStateOf(false) }
    BackHandler(onBack = onBack)
    if (details) AlertDialog(onDismissRequest = { details = false }, title = { Text("Connection details") },
        text = { SelectionContainer { Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(state.origin)
            state.host?.let { Text("Computer: ${it.name}") }
            if (state.workspaceID != null) Text("Workspace: ${state.workspaceTitle}")
            state.sessionID?.let { Text("Session: $it", fontFamily = FontFamily.Monospace) }
            state.model?.let { Text("Model: ${state.provider} / $it${state.effort?.let { effort -> " · $effort" } ?: ""}") }
        } } }, confirmButton = { TextButton(onClick = { details = false }) { Text("Done") } })
    if (presentation) RemotePresentation(controller, onDismiss = { presentation = false })
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(horizontal = 16.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = onBack, modifier = Modifier.testTag("remote.back")) { Text("Back") }
                Text("My computer", style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.weight(1f).padding(vertical = 12.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Box {
                    TextButton(onClick = { more = true }, modifier = Modifier.testTag("remote.more")) { Text("More") }
                    DropdownMenu(more, onDismissRequest = { more = false }) {
                        DropdownMenuItem(text = { Text("Connection details") }, onClick = { more = false; details = true })
                        state.sessionID?.let { id -> DropdownMenuItem(text = { Text("Copy session ID") }, onClick = {
                            more = false; clipboard.setText(AnnotatedString(id))
                        }, modifier = Modifier.testTag("remote.copySessionID")) }
                        DropdownMenuItem(text = { Text("Reading preferences") }, onClick = { more = false; presentation = true })
                        if (state.workspaces.isNotEmpty()) state.workspaces.forEach { workspace ->
                            DropdownMenuItem(text = { Text("Sessions · ${workspace.title}") }, enabled = !state.busy, onClick = {
                                more = false; controller.workspace(workspace.id)
                            })
                        }
                        if (state.phase !in setOf(RemoteHarnessClientPhase.SETUP, RemoteHarnessClientPhase.AUTHORIZING))
                            DropdownMenuItem(text = { Text("Disconnect") }, onClick = { more = false; controller.disconnect() },
                                modifier = Modifier.testTag("remote.disconnect"))
                    }
                }
            }
            val destination = listOfNotNull(state.host?.name, state.workspaceTitle.takeIf { state.workspaceID != null }).joinToString(" · ")
            if (destination.isNotEmpty()) Text(destination, style = MaterialTheme.typography.labelMedium,
                maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.testTag("remote.destination"))
            Text(status(state), modifier = Modifier.testTag("remote.status"), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            controller.inputError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("remote.error").padding(vertical = 8.dp)) }
            if (!state.approvalSupported && state.phase in setOf(RemoteHarnessClientPhase.WORKSPACES, RemoteHarnessClientPhase.SESSIONS, RemoteHarnessClientPhase.SESSION))
                Text("This Host is read-only. Install and enable the Quenderin Remote companion on your computer, approve this device there, then reconnect.",
                    modifier = Modifier.testTag("remote.companionRequired").padding(vertical = 8.dp), style = MaterialTheme.typography.bodySmall)
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().testTag("remote.busy"))
            when (state.phase) {
                RemoteHarnessClientPhase.SETUP, RemoteHarnessClientPhase.AUTHORIZING -> RemoteSetup(controller, state)
                RemoteHarnessClientPhase.HOSTS -> Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Choose an authorized computer", style = MaterialTheme.typography.titleMedium)
                    Text("Start DeepSeek Harness and the Quenderin Remote companion on that computer. Approve this device there when prompted.")
                    RemotePairingIdentity(state)
                    TextButton(onClick = controller::hosts, enabled = !state.busy, modifier = Modifier.testTag("remote.refreshHosts")) { Text("Refresh computers") }
                    if (state.hosts.isEmpty()) Text("No computers are registered with this account.")
                    state.hosts.forEach { host -> OutlinedButton(onClick = { controller.chooseHost(host.deviceID) }, enabled = !state.busy,
                        modifier = Modifier.fillMaxWidth().testTag("remote.host.${host.deviceID}")) {
                        Text("${host.name} · ${if (host.online) "Online" else "Offline"}")
                    } }
                }
                RemoteHarnessClientPhase.CONFIRM_PIN -> RemoteConfirmPin(controller, state)
                RemoteHarnessClientPhase.CONNECTING -> Column(Modifier.padding(vertical = 20.dp)) {
                    CircularProgressIndicator()
                    Text("Connecting securely to your computer…", modifier = Modifier.padding(top = 12.dp))
                    Text("If prompted, approve this device in the computer's Remote companion.")
                }
                RemoteHarnessClientPhase.WORKSPACES -> Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Choose a workspace on your computer", style = MaterialTheme.typography.titleMedium)
                    if (state.workspaces.isEmpty()) Text("No workspace has been returned by the Host. Create or open one in DeepSeek Harness, then wait for its workspace stream.")
                    state.workspaces.forEach { workspace -> OutlinedButton(onClick = { controller.workspace(workspace.id) }, modifier = Modifier.fillMaxWidth().testTag("remote.workspace.${workspace.id}")) {
                        Column { Text(workspace.title); Text(workspace.path, style = MaterialTheme.typography.bodySmall) }
                    } }
                }
                RemoteHarnessClientPhase.SESSIONS -> LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("remote.sessions"),
                    verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
                    item(key = "section:sessions") {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Sessions", style = MaterialTheme.typography.titleMedium)
                            Button(onClick = controller::createSession, enabled = state.approvalSupported && !state.busy,
                                modifier = Modifier.testTag("remote.createSession")) { Text("New session on computer") }
                            if (state.sessions.isEmpty()) Text("No sessions in this workspace yet.")
                        }
                    }
                    itemsIndexed(state.sessions, key = { index, session -> "session:$index:${session.id}" }) { _, session -> OutlinedButton(onClick = { controller.session(session.id) }, enabled = !state.busy,
                        modifier = Modifier.fillMaxWidth().testTag("remote.session.${session.id}")) {
                        Text(session.title + if (session.running) " · Running" else "")
                    } }
                    item(key = "section:bots") { RemoteBotStatus(controller, state, Modifier.padding(top = 12.dp)) }
                    items(state.botRoster?.bots.orEmpty(), key = { "bot:${it.id}" }) { bot ->
                        RemoteBotRow(bot, available = bot.id in state.availableBotIDs, enabled = !state.busy,
                            onClick = { controller.bot(bot.id) })
                    }
                }
                RemoteHarnessClientPhase.SESSION -> RemoteSession(controller, state, Modifier.weight(1f))
                RemoteHarnessClientPhase.DISCONNECTED -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = controller::reconnect, enabled = controller.securityAvailable && !state.busy,
                            modifier = Modifier.testTag("remote.reconnect")) { Text("Reconnect") }
                        TextButton(onClick = controller::hosts, enabled = controller.securityAvailable && !state.busy) { Text("Computers") }
                    }
                    if (state.sessionID != null) RemoteSession(controller, state, Modifier.weight(1f))
                    if (state.error?.contains("Sign in") == true || state.sessionID == null) RemoteSetup(controller, state)
                }
                RemoteHarnessClientPhase.BLOCKED -> {
                    if (state.error?.contains("refresh") == true) RemoteSetup(controller, state)
                    else Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                        Text("Your saved connection and conversations remain on this device.")
                        state.unsavedScopedDraft?.let { unsaved ->
                            Text("Unsaved draft · ${unsaved.scope.sessionID ?: "new session"}", style = MaterialTheme.typography.titleSmall)
                            RemoteRawText(unsaved.text, controller, "draft", monospace = false)
                        }
                        if (state.draft.isNotEmpty()) {
                            Text("Current draft", style = MaterialTheme.typography.titleSmall)
                            RemoteRawText(state.draft, controller, "draft", monospace = false)
                        }
                    }
                }
            }
        }
    }
}

private fun status(s: RemoteHarnessClientSnapshot): String = when (s.status) {
    RemoteSessionStatus.CONNECTING -> "Connecting"
    RemoteSessionStatus.READY -> when {
        !s.historyReady && s.sessionID != null -> "Loading authoritative history"
        s.botSessionReadOnly -> "Connected · view-only Bot history"
        else -> "Connected · execution on computer"
    }
    RemoteSessionStatus.RUNNING -> "Running on computer"
    RemoteSessionStatus.AWAITING_APPROVAL -> "Computer needs your approval"
    RemoteSessionStatus.STOP_REQUESTED -> "Stop requested · waiting for computer confirmation"
    RemoteSessionStatus.STOPPED -> "Computer confirmed: stopped"
    RemoteSessionStatus.OUTCOME_UNKNOWN -> "Outcome unknown · reconnect to check the computer"
    RemoteSessionStatus.DISCONNECTED -> "Disconnected · saved history"
}

@Composable private fun RemoteSetup(controller: RemoteHarnessController, state: RemoteHarnessClientSnapshot) {
    var origin by remember(state.origin) { mutableStateOf(state.origin) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Connect to your self-hosted Remote server", style = MaterialTheme.typography.titleMedium)
        Text("Use the account configured by your server administrator. Your password is used only for device setup. Your computer keeps its model provider credentials.")
        OutlinedTextField(origin, { origin = it }, label = { Text("HTTPS server origin") }, placeholder = { Text("https://remote.example.org") },
            singleLine = true, enabled = !state.busy && state.deviceID.isEmpty(), modifier = Modifier.fillMaxWidth().testTag("remote.origin"))
        OutlinedTextField(email, { email = it }, label = { Text("Server account email") }, singleLine = true,
            enabled = !state.busy && controller.securityAvailable, modifier = Modifier.fillMaxWidth().testTag("remote.email"))
        RemotePassword(password, { password = it }, enabled = !state.busy && controller.securityAvailable)
        Button(onClick = { val entry = password.toCharArray(); password = ""; controller.authorize(origin, email, entry) },
            enabled = controller.securityAvailable && !state.busy && origin.isNotBlank() && email.isNotBlank() && password.isNotEmpty(),
            modifier = Modifier.fillMaxWidth().testTag("remote.authorize")) { Text("Authorize this device") }
    }
}

@Composable private fun RemoteConfirmPin(controller: RemoteHarnessController, state: RemoteHarnessClientSnapshot) {
    val host = state.pendingHost ?: return
    var compared by remember(host.deviceID, host.fingerprint) { mutableStateOf(false) }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Verify ${host.name}", style = MaterialTheme.typography.titleMedium)
        Text("Compare this complete SHA-256 identity fingerprint with the one shown by the Remote companion on your computer.")
        SelectionContainer { Text(host.fingerprint ?: "", fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("remote.fullPin")) }
        Row { Checkbox(compared, { compared = it }, modifier = Modifier.testTag("remote.pinCompared")); Text("I compared the complete fingerprint on my computer.", modifier = Modifier.padding(top = 12.dp)) }
        Button(onClick = { controller.confirmHost(host.fingerprint ?: "") }, enabled = compared, modifier = Modifier.testTag("remote.confirmPin")) { Text("Trust and connect") }
        Text("A changed computer identity will require verification again. This confirmation does not replace approval on the computer.", style = MaterialTheme.typography.bodySmall)
        RemotePairingIdentity(state)
    }
}

@Composable private fun RemotePairingIdentity(state: RemoteHarnessClientSnapshot) {
    if (state.clientPublicIdentity == null || state.clientFingerprint == null) return
    Text("Authorize this Android device in the computer's Remote companion:", style = MaterialTheme.typography.labelLarge)
    SelectionContainer { Column {
        Text("Device ID: ${state.deviceID}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        Text("Public identity: ${state.clientPublicIdentity}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        Text("SHA-256: ${state.clientFingerprint}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.testTag("remote.clientFullPin"))
    } }
}

@Composable private fun RemoteBotStatus(controller: RemoteHarnessController, state: RemoteHarnessClientSnapshot, modifier: Modifier = Modifier) {
    val roster = state.botRoster
    val rosterError = state.botRosterError
    Column(modifier.fillMaxWidth().testTag("remote.bots"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Bots", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).padding(top = 12.dp))
            TextButton(onClick = controller::refreshBots, enabled = state.botReadSupported && !state.botRosterLoading,
                modifier = Modifier.testTag("remote.refreshBots")) { Text("Refresh bots") }
        }
        when {
            !state.botReadSupported -> Text("This connection does not support Bot viewing. Enable the Bot integration on your computer, then reconnect.",
                modifier = Modifier.testTag("remote.botsUnsupported"), style = MaterialTheme.typography.bodySmall)
            state.botRosterLoading -> {
                LinearProgressIndicator(Modifier.fillMaxWidth().testTag("remote.botsLoading"))
                Text("Refreshing bots…", style = MaterialTheme.typography.bodySmall)
            }
            rosterError != null -> Text(rosterError, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("remote.botsUnavailable"), style = MaterialTheme.typography.bodySmall)
            roster == null -> Text("Bots have not been loaded. Refresh to check this workspace.",
                modifier = Modifier.testTag("remote.botsNotLoaded"), style = MaterialTheme.typography.bodySmall)
            roster.bots.isEmpty() -> Text("No bots in this workspace.",
                modifier = Modifier.testTag("remote.botsEmpty"), style = MaterialTheme.typography.bodySmall)
            else -> Text("${roster.bots.size} bots · view-only history",
                modifier = Modifier.testTag("remote.botsReady"), style = MaterialTheme.typography.bodySmall)
        }
        if (roster != null) {
            if (state.botRosterLoading || state.botRosterError != null)
                Text("Previously received bots remain visible. Refresh must finish successfully before opening their sessions.",
                    style = MaterialTheme.typography.bodySmall)
            Text(if (roster.readOnly) "Computer reports read-only Bot data."
                else "Computer does not mark Bot data read-only. Bot history remains view-only here.",
                modifier = Modifier.testTag("remote.botsReadOnly"), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable private fun RemoteBotRow(bot: RemoteHarnessBotSummary, available: Boolean, enabled: Boolean, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, enabled = enabled && available, contentPadding = PaddingValues(12.dp),
        modifier = Modifier.fillMaxWidth().testTag("remote.bot.${bot.id}")) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(bot.name, style = MaterialTheme.typography.titleSmall)
            Text("Model: ${bot.model ?: "Not reported"}", style = MaterialTheme.typography.bodySmall)
            Text("Permission: ${bot.permission ?: "Not reported"}", style = MaterialTheme.typography.bodySmall)
            Text(if (available) "View current history" else "Current session is not available for viewing",
                style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable private fun RemoteSession(controller: RemoteHarnessController, state: RemoteHarnessClientSnapshot, modifier: Modifier) {
    var localDraft by remember(state.draftScope) { mutableStateOf(state.draft) }
    LaunchedEffect(state.draftScope, state.draft) { if (state.draft.isEmpty() || localDraft.isEmpty()) localDraft = state.draft }
    val sessionMutationsAllowed = !state.botSessionReadOnly && !state.botSessionClassificationPending
    val modelChangesAllowed = sessionMutationsAllowed && state.approvalSupported && state.historyReady && state.models.isNotEmpty() && !state.busy
    Column(modifier.fillMaxWidth()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("remote.timeline"), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
            if (state.botReadSupported || state.botSessionReadOnly || state.botSessionClassificationPending) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (state.botSessionReadOnly) Text("Bot history is view-only. Run tasks and change this bot's model on your computer.",
                        modifier = Modifier.testTag("remote.botSessionReadOnly"), style = MaterialTheme.typography.bodyMedium)
                    else if (state.botSessionClassificationPending) Text("Verify this session before sending tasks or changing its model. Your draft and history are preserved.",
                        modifier = Modifier.testTag("remote.botClassificationPending"), style = MaterialTheme.typography.bodyMedium)
                    RemoteBotStatus(controller, state)
                    if (state.botSessionClassificationPending && !state.botRosterLoading)
                        TextButton(onClick = controller::reconnect, enabled = controller.securityAvailable && !state.busy,
                            modifier = Modifier.testTag("remote.recoverBots")) { Text("Reconnect to verify session") }
                }
            }
            if (state.hasMore) item { TextButton(onClick = controller::earlierHistory, enabled = state.historyReady && !state.busy) { Text("Load earlier history") } }
            items(state.timeline, key = { it.id }) { item ->
                Column(Modifier.fillMaxWidth().testTag("remote.message.${item.id}")) {
                    Text(when (item.kind) { "user" -> "You"; "assistant" -> "Harness"; "tool" -> "Computer tool"; else -> "Computer" }, style = MaterialTheme.typography.labelLarge)
                    if (item.reasoning.isNotEmpty()) {
                        var expanded by remember(item.id) { mutableStateOf(false) }
                        TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) { Text(if (expanded) "Hide reasoning" else "Show reasoning") }
                        if (expanded) RemoteRawText(item.reasoning, controller, "reasoning", monospace = false)
                    }
                    if (item.text.isNotEmpty()) {
                        if (item.kind == "assistant") {
                            val clipboard = LocalClipboardManager.current
                            if (remoteMarkdownFormattingAllowed(item.text)) {
                                MarkdownText(item.text, MaterialTheme.colorScheme.onSurface,
                                    baseStyle = MaterialTheme.typography.bodyLarge.copy(fontSize = if (controller.largeText) 18.sp else 16.sp),
                                    wrapCode = controller.wrapCode, codeFontSize = if (controller.largeText) 15.sp else 13.sp, showsCodeCopyButton = true)
                                TextButton(onClick = { clipboard.setText(AnnotatedString(item.text)) }) { Text("Copy response") }
                            } else {
                                Text("Formatting is limited for this long or complex response. Exact text remains available below.", style = MaterialTheme.typography.bodySmall)
                                RemoteRawText(item.text, controller, "response", monospace = false)
                            }
                        } else RemoteRawText(item.text, controller, if (item.kind == "tool") "tool output" else "message", monospace = item.kind == "tool")
                    }
                }
            }
            if (!state.approvalSupported) item { Text("Tool approval requires the Quenderin Remote companion extension on your computer.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            items(state.approvals, key = { "approval-${it.eventID}" }) { approval ->
                val action = state.approvalActions[approval.eventID]
                Column(Modifier.fillMaxWidth().testTag("remote.approval.${approval.eventID}")) {
                    Text("Allow this computer action?", style = MaterialTheme.typography.titleSmall)
                    if (action == null) {
                        Text("Waiting for full action details from your computer. You can stop the task while waiting.",
                            style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("remote.approvalWaiting.${approval.eventID}"))
                    } else {
                        Text("Tool: ${action.toolName}", style = MaterialTheme.typography.labelLarge)
                        SelectionContainer { Text("Call ID: ${action.callID}", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
                        Text("Exact arguments", style = MaterialTheme.typography.labelMedium)
                        RemoteRawText(action.arguments, controller, "arguments", Modifier.testTag("remote.approvalArguments.${approval.eventID}"))
                    }
                    Text("Approval request metadata", style = MaterialTheme.typography.labelMedium)
                    RemoteRawText(RemoteHarnessJSON.write(approval.request), controller, "approval metadata")
                    Text("Applies once to this device, workspace, session and active turn. Expires in at most two minutes.", style = MaterialTheme.typography.bodySmall)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { controller.decideApproval(approval.eventID, true) }, enabled = action != null && state.historyReady && !state.busy,
                            modifier = Modifier.testTag("remote.approve.${approval.eventID}")) { Text("Allow once") }
                        OutlinedButton(onClick = { controller.decideApproval(approval.eventID, false) }, enabled = action != null && state.historyReady && !state.busy,
                            modifier = Modifier.testTag("remote.deny.${approval.eventID}")) { Text("Deny") }
                    }
                }
            }
        }
        var showModels by remember(state.draftScope) { mutableStateOf(false) }
        LaunchedEffect(modelChangesAllowed) { if (!modelChangesAllowed) showModels = false }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            if (!state.botSessionReadOnly) Box(Modifier.weight(1f)) {
                TextButton(onClick = { showModels = true }, enabled = modelChangesAllowed,
                    modifier = Modifier.testTag("remote.models")) { Text("Model and effort") }
                DropdownMenu(showModels && modelChangesAllowed, onDismissRequest = { showModels = false }) {
                    state.models.forEach { model ->
                        DropdownMenuItem(text = { Text("${model.provider} / ${model.name}") }, enabled = modelChangesAllowed, onClick = {
                            showModels = false; controller.selectModel(model.provider, model.id, null)
                        })
                        model.efforts.forEach { effort -> DropdownMenuItem(text = { Text("${model.name} · ${effort.second}") }, enabled = modelChangesAllowed, onClick = {
                            showModels = false; controller.selectModel(model.provider, model.id, effort.first)
                        }) }
                    }
                }
            }
            if (state.status in setOf(RemoteSessionStatus.RUNNING, RemoteSessionStatus.AWAITING_APPROVAL, RemoteSessionStatus.STOP_REQUESTED))
                TextButton(onClick = controller::stop, enabled = state.historyReady && state.status != RemoteSessionStatus.STOP_REQUESTED,
                    modifier = Modifier.weight(1f).testTag("remote.stop")) { Text("Stop on computer") }
        }
        if (!state.botSessionReadOnly) {
            OutlinedTextField(localDraft, { localDraft = it; controller.draft(it, state.draftScope) }, label = { Text("Task for your computer") }, minLines = 2, maxLines = 6,
                modifier = Modifier.fillMaxWidth().testTag("remote.composer"), enabled = sessionMutationsAllowed && !state.busy)
            Button(onClick = { controller.send(state.draftScope, localDraft) }, enabled = sessionMutationsAllowed && state.approvalSupported && state.historyReady && !state.busy && localDraft.isNotBlank() && state.status != RemoteSessionStatus.OUTCOME_UNKNOWN,
                modifier = Modifier.fillMaxWidth().testTag("remote.send").padding(vertical = 8.dp)) { Text("Send to computer") }
        }
    }
}

/** Full source stays available for copying. Rendering is limited to one 16 KiB section. */
@Composable private fun RemoteRawText(text: String, controller: RemoteHarnessController, label: String,
    modifier: Modifier = Modifier, monospace: Boolean = true) {
    val clipboard = LocalClipboardManager.current
    var expanded by remember(text) { mutableStateOf(false) }
    var section by remember(text) { mutableIntStateOf(0) }
    val sections = remember(text) { remoteTextSections(text) }
    val displayed = if (expanded) sections[section] else remoteTextPreview(text)
    Column(modifier.fillMaxWidth()) {
        SelectionContainer {
            Text(displayed, style = MaterialTheme.typography.bodyMedium.copy(fontSize = if (controller.largeText) 18.sp else 14.sp),
                fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default,
                modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())
                    .then(if (!monospace || controller.wrapCode) Modifier else Modifier.horizontalScroll(rememberScrollState())))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { clipboard.setText(AnnotatedString(text)) }) { Text("Copy exact $label") }
            if (text.length > 2_048) TextButton(onClick = { expanded = !expanded; section = 0 }) { Text(if (expanded) "Collapse" else "Expand") }
        }
        if (expanded && sections.size > 1) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { section-- }, enabled = section > 0) { Text("Previous") }
            Text("${section + 1} / ${sections.size}", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 16.dp))
            TextButton(onClick = { section++ }, enabled = section < sections.lastIndex) { Text("Next") }
        }
    }
}

@Composable private fun RemotePresentation(controller: RemoteHarnessController, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Reading preferences") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text("Saved on this Android device.", style = MaterialTheme.typography.bodySmall)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Wrap code and tool output", Modifier.weight(1f).padding(top = 12.dp))
                Switch(controller.wrapCode, controller::wrapCode, modifier = Modifier.testTag("remote.wrapCode"))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Larger conversation text", Modifier.weight(1f).padding(top = 12.dp))
                Switch(controller.largeText, controller::largeText, modifier = Modifier.testTag("remote.largeText"))
            }
        }
    }, confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } })
}

/** Password entry is intentionally excluded from SavedState, autofill, content capture and IME learning. */
@Composable private fun RemotePassword(value: String, onChange: (String) -> Unit, enabled: Boolean) {
    val latest by rememberUpdatedState(onChange)
    var editor by remember { mutableStateOf<EditText?>(null) }
    DisposableEffect(Unit) { onDispose { editor?.text?.clear(); editor = null } }
    Column {
        Text("Server password", style = MaterialTheme.typography.labelLarge)
        AndroidView(modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag("remote.password"), factory = { context -> EditText(context).apply {
            editor = this; hint = "Password"; isSingleLine = true; isSaveEnabled = false; isSaveFromParentEnabled = false
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            if (android.os.Build.VERSION.SDK_INT >= 29) importantForContentCapture = View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_DONE
            filters = arrayOf(android.text.InputFilter.LengthFilter(1024)); isLongClickable = false
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { latest(s?.toString() ?: "") }
                override fun afterTextChanged(s: Editable?) {}
            })
        } }, update = { view -> view.isEnabled = enabled
            if (view.text.toString() != value) { view.setText(value); view.setSelection(value.length) }
        })
    }
}
