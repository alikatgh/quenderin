package ai.quenderin.app.ui

import ai.quenderin.app.RemoteHarnessController
import ai.quenderin.core.*
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** Native remote destination; it consumes only RemoteHarnessController state and events. */
@Composable
fun RemoteHarnessScreen(controller: RemoteHarnessController, onBack: () -> Unit) {
    val state = controller.state
    BackHandler(onBack = onBack)
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(horizontal = 16.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = onBack, modifier = Modifier.testTag("remote.back")) { Text("Back") }
                if (state.phase !in setOf(RemoteHarnessClientPhase.SETUP, RemoteHarnessClientPhase.AUTHORIZING)) {
                    TextButton(onClick = controller::disconnect, modifier = Modifier.testTag("remote.disconnect")) { Text("Disconnect") }
                }
            }
            Text("My computer", style = MaterialTheme.typography.headlineSmall)
            Text("DeepSeek Harness runs on your computer.", style = MaterialTheme.typography.bodyMedium)
            if (state.origin.isNotEmpty()) Text(state.origin, style = MaterialTheme.typography.labelMedium, modifier = Modifier.testTag("remote.server"))
            state.host?.let { Text("Computer: ${it.name}", modifier = Modifier.testTag("remote.host"), style = MaterialTheme.typography.labelLarge) }
            if (state.workspaceID != null) Text("Workspace: ${state.workspaceTitle}", modifier = Modifier.testTag("remote.workspace"), style = MaterialTheme.typography.labelMedium)
            state.sessionID?.let { Text("Session: $it", modifier = Modifier.testTag("remote.session"), style = MaterialTheme.typography.labelSmall) }
            state.model?.let { Text("Model: ${state.provider} / $it${state.effort?.let { effort -> " · $effort" } ?: ""}", style = MaterialTheme.typography.labelMedium) }
            Text(status(state), modifier = Modifier.testTag("remote.status"), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
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
                RemoteHarnessClientPhase.SESSIONS -> Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Sessions", style = MaterialTheme.typography.titleMedium)
                    Button(onClick = controller::createSession, enabled = state.approvalSupported && !state.busy, modifier = Modifier.testTag("remote.createSession")) { Text("New session on computer") }
                    if (state.sessions.isEmpty()) Text("No sessions in this workspace yet.")
                    state.sessions.forEach { session -> OutlinedButton(onClick = { controller.session(session.id) }, enabled = !state.busy,
                        modifier = Modifier.fillMaxWidth().testTag("remote.session.${session.id}")) {
                        Text(session.title + if (session.running) " · Running" else "")
                    } }
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
                    else Text("Your saved connection and conversations remain on this device.")
                }
            }
        }
    }
}

private fun status(s: RemoteHarnessClientSnapshot): String = when (s.status) {
    RemoteSessionStatus.CONNECTING -> "Connecting"
    RemoteSessionStatus.READY -> if (s.historyReady || s.sessionID == null) "Connected · execution on computer" else "Loading authoritative history"
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

@Composable private fun RemoteSession(controller: RemoteHarnessController, state: RemoteHarnessClientSnapshot, modifier: Modifier) {
    var localDraft by remember(state.sessionID) { mutableStateOf(state.draft) }
    LaunchedEffect(state.draft) { if (state.draft.isEmpty() || localDraft.isEmpty()) localDraft = state.draft }
    Column(modifier.fillMaxWidth()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("remote.timeline"), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
            if (state.hasMore) item { TextButton(onClick = controller::earlierHistory, enabled = state.historyReady && !state.busy) { Text("Load earlier history") } }
            items(state.timeline, key = { it.id }) { item ->
                Column(Modifier.fillMaxWidth().testTag("remote.message.${item.id}")) {
                    Text(when (item.kind) { "user" -> "You"; "assistant" -> "Harness"; "tool" -> "Computer tool"; else -> "Computer" }, style = MaterialTheme.typography.labelLarge)
                    if (item.reasoning.isNotEmpty()) {
                        var expanded by remember(item.id) { mutableStateOf(false) }
                        TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) { Text(if (expanded) "Hide reasoning" else "Show reasoning") }
                        if (expanded) SelectionContainer { Text(item.reasoning, style = MaterialTheme.typography.bodySmall) }
                    }
                    if (item.text.isNotEmpty()) SelectionContainer { Text(item.text, fontFamily = if (item.kind == "tool") FontFamily.Monospace else FontFamily.Default) }
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
                        SelectionContainer { Text(action.arguments, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                            modifier = Modifier.testTag("remote.approvalArguments.${approval.eventID}")) }
                    }
                    Text("Approval request metadata", style = MaterialTheme.typography.labelMedium)
                    SelectionContainer { Text(RemoteHarnessJSON.write(approval.request), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
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
        var showModels by remember { mutableStateOf(false) }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Box {
                TextButton(onClick = { showModels = true }, enabled = state.approvalSupported && state.historyReady && state.models.isNotEmpty() && !state.busy,
                    modifier = Modifier.testTag("remote.models")) { Text("Model and effort") }
                DropdownMenu(showModels, onDismissRequest = { showModels = false }) {
                    state.models.forEach { model ->
                        DropdownMenuItem(text = { Text("${model.provider} / ${model.name}") }, enabled = state.approvalSupported && state.historyReady && !state.busy, onClick = {
                            showModels = false; controller.selectModel(model.provider, model.id, null)
                        })
                        model.efforts.forEach { effort -> DropdownMenuItem(text = { Text("${model.name} · ${effort.second}") }, enabled = state.approvalSupported && state.historyReady && !state.busy, onClick = {
                            showModels = false; controller.selectModel(model.provider, model.id, effort.first)
                        }) }
                    }
                }
            }
            if (state.status in setOf(RemoteSessionStatus.RUNNING, RemoteSessionStatus.AWAITING_APPROVAL, RemoteSessionStatus.STOP_REQUESTED))
                TextButton(onClick = controller::stop, enabled = state.historyReady && state.status != RemoteSessionStatus.STOP_REQUESTED,
                    modifier = Modifier.testTag("remote.stop")) { Text("Stop on computer") }
        }
        OutlinedTextField(localDraft, { localDraft = it; controller.draft(it) }, label = { Text("Task for your computer") }, minLines = 2, maxLines = 6,
            modifier = Modifier.fillMaxWidth().testTag("remote.composer"), enabled = !state.busy)
        Button(onClick = controller::send, enabled = state.approvalSupported && state.historyReady && !state.busy && localDraft.isNotBlank() && state.status != RemoteSessionStatus.OUTCOME_UNKNOWN,
            modifier = Modifier.fillMaxWidth().testTag("remote.send").padding(vertical = 8.dp)) { Text("Send to computer") }
    }
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
