package ai.quenderin.app.ui

import ai.quenderin.app.AgentGoalHistoryStore
import ai.quenderin.app.DocTree
import ai.quenderin.app.DocUndoJournal
import ai.quenderin.app.PrefsConsentStore
import ai.quenderin.app.SafDocTree
import ai.quenderin.app.copyAttachmentToCache
import ai.quenderin.app.docWorkspaceCapabilities
import ai.quenderin.core.AgentGoalEntry
import ai.quenderin.core.ActionPreview
import ai.quenderin.core.AgentDecision
import ai.quenderin.core.AgentRun
import ai.quenderin.core.AgentSession
import ai.quenderin.core.AgentStep
import ai.quenderin.core.AgentTool
import ai.quenderin.core.ApprovalBroker
import ai.quenderin.core.CapabilityRunner
import ai.quenderin.core.FileAuditLedger
import ai.quenderin.core.FileReadCapability
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.SupportContact
import ai.quenderin.core.userMessage
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.runtime.mutableStateMapOf
import java.io.File
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
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
    val context = LocalContext.current
    var steps by remember { mutableStateOf<List<AgentStep>>(emptyList()) }
    var answer by remember { mutableStateOf<String?>(null) }
    var running by remember { mutableStateOf(false) }
    var haltReason by remember { mutableStateOf<AgentRun.HaltReason?>(null) }
    var goal by remember { mutableStateOf("") }
    // Every goal the user has run, newest first — the re-use affordance (twin of iOS
    // AgentRecentGoals). The store persists via SharedPreferences (async apply, no
    // main-thread I/O); this snapshot mirrors it into Compose state.
    val goalHistory = remember { AgentGoalHistoryStore(context) }
    var recentGoals by remember { mutableStateOf(goalHistory.entries) }

    // ── Governance wiring (the iOS AgentView twin, previously missing on Android — every
    // T1+ capability fail-closed refused because the app never injected a runner). ──
    // Attached files: the ONLY door into fs.read's granted map (a user pick, never a model path).
    val attachments = remember { mutableStateMapOf<String, File>() }
    // The approval dialog's broker: the agent thread blocks in request(); Compose shows the
    // dialog from onRequest and answers on the main thread. Dismissal = NO.
    var pendingApproval by remember { mutableStateOf<ActionPreview?>(null) }
    val broker = remember {
        ApprovalBroker().apply {
            onRequest = { preview -> scope.launch(Dispatchers.Main.immediate) { pendingApproval = preview } }
        }
    }
    val consent = remember { PrefsConsentStore(context) }
    var fsReadGranted by remember { mutableStateOf(consent.isGranted("fs.read")) }
    // The workspace: ONE folder the user grants via the system picker (SAF tree). The grant URI
    // persists across relaunches; the tree is rebuilt from it (null when the grant is gone).
    val workspacePrefs = remember { context.getSharedPreferences("quenderin", android.content.Context.MODE_PRIVATE) }
    var workspaceTree by remember {
        mutableStateOf<DocTree?>(
            workspacePrefs.getString("workspace.treeUri", null)
                ?.let { runCatching { SafDocTree.fromGrant(context, Uri.parse(it)) }.getOrNull() },
        )
    }
    var workspaceGranted by remember { mutableStateOf(consent.isGranted("fs.move")) }
    val undoJournal = remember { DocUndoJournal() }
    var undoCount by remember { mutableStateOf(0) }
    var undoNotice by remember { mutableStateOf<String?>(null) }
    val pickWorkspace = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            workspacePrefs.edit().putString("workspace.treeUri", uri.toString()).apply()
            workspaceTree = SafDocTree.fromGrant(context, uri)
        }
    }
    val session = remember {
        val runner = CapabilityRunner(
            consent = consent,
            ledger = FileAuditLedger(File(context.filesDir, "agent-ledger.jsonl")),
            approve = { preview -> broker.request(preview) },
        )
        val allTools = tools +
            FileReadCapability(grantedFiles = { attachments.toMap() }) +
            docWorkspaceCapabilities(workspace = { workspaceTree }, journal = undoJournal) +
            // T1 device perception (owner sign-off 2026-07-07) — read-only senses, consent-gated
            // like everything else; the Settings pane lists them from the same classes.
            ai.quenderin.app.devicePerceptionCapabilities(context)
        AgentSession(engine, allTools, runner = runner).apply {
            onChange = {
                // Q-228 twin: run() executes on Dispatchers.IO (below), so onChange fires from a background
                // thread — writing Compose snapshot state directly off the main thread is a threading
                // violation (missed/torn recompositions; a crash in strict/debug builds). Snapshot the
                // session's values here, then marshal the Compose writes onto the main dispatcher, exactly
                // like the ChatScreen fix. Main.immediate keeps a same-thread emit synchronous.
                val s = this.steps
                val a = this.answer
                val r = this.isRunning
                val h = this.haltReason
                scope.launch(Dispatchers.Main.immediate) {
                    steps = s
                    answer = a
                    running = r
                    haltReason = h
                    undoCount = undoJournal.count   // a run's moves surface the Undo button live
                }
            }
        }
    }
    // The document picker — the user's attach gesture is what populates fs.read's map. The pick
    // is copied into the app cache at attach time (see copyAttachmentToCache), so no SAF grant
    // has to outlive this moment.
    val pickDocument = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            scope.launch(Dispatchers.IO) {
                val copied = copyAttachmentToCache(context, uri)
                if (copied != null) {
                    scope.launch(Dispatchers.Main.immediate) { attachments[copied.first] = copied.second }
                }
            }
        }
    }

    val hasContent = steps.isNotEmpty() || answer != null || haltReason != null

    // No nested Scaffold/TopAppBar: this screen already sits inside MainTabs' Scaffold, which applies the
    // status-bar inset once. A second Scaffold+TopAppBar re-applied it — the big empty band above the
    // title. A plain titled column avoids that double inset. imePadding() lifts the goal field above the
    // soft keyboard (twin of ChatScreen); MainTabs consumes the nav-bar inset so the field docks onto the
    // keyboard with no gap.
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Agent",
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = { session.clear() }, enabled = !running && hasContent) { Text("Clear") }
        }

        if (!hasContent && !running) {
            // Centered guidance (twin of chat's centered empty state) — no top-stuck block with a big
            // empty middle. Below the examples: the user's own recent goals, tap to re-use,
            // long-press to remove, one button to forget all (twin of iOS AgentRecentGoals).
            AgentEmptyState(
                Modifier.weight(1f),
                onPick = { goal = it },
                recents = recentGoals,
                onRemoveRecent = { recentGoals = goalHistory.remove(it) },
                onClearRecents = { recentGoals = goalHistory.clear() },
            )
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(steps) { step -> AgentStepRow(step) }
                // While a run is live, SOMETHING must always be visibly happening — before this
                // row the screen was BLANK from Run until the first step landed, and the first
                // decision is the mission's slowest decode, so real goals read as "it just stuck"
                // (live user report on the Mac twin; same gap here). Twin of iOS AgentWorkingRow.
                if (running) {
                    item { AgentWorkingRow(stepNumber = steps.size + 1, firstStep = steps.isEmpty()) }
                }
                answer?.let { a ->
                    item {
                        // Long-press the answer to report it (Generative-AI flag mechanism).
                        // Hoisted so TalkBack can reach it via a semantics custom action too.
                        val reportAnswer = {
                            val intent = Intent(Intent.ACTION_SENDTO, Uri.parse(SupportContact.reportMailtoUri(a, "agent")))
                            runCatching { context.startActivity(intent) }
                            Unit
                        }
                        Surface(
                            color = MaterialTheme.colorScheme.primaryContainer,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .combinedClickable(onClick = {}, onLongClick = reportAnswer)
                                .semantics {
                                    customActions = listOf(
                                        CustomAccessibilityAction("Report this answer") { reportAnswer(); true },
                                    )
                                },
                        ) {
                            MarkdownText(
                                text = a,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(12.dp),
                            )
                        }
                    }
                }
                // The agent stopped without an answer (step limit, safety gate, plan error):
                // say so instead of trailing off into silence.
                if (answer == null && !running) {
                    haltReason?.userMessage?.let { msg -> item { AgentHaltBanner(msg) } }
                }
            }
        }

        // Attachments: the only door into fs.read. Chips (tap to remove) + the consent switch —
        // consent lives WHERE the feature lives, granted by a visible user gesture (twin of the
        // iOS Settings toggle; a Settings pane twin can follow).
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = { pickDocument.launch(arrayOf("text/*", "application/json", "application/xml")) }, enabled = !running) {
                Text("Attach file")
            }
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                attachments.keys.sorted().take(3).forEach { name ->
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = RoundedCornerShape(50),
                        modifier = Modifier.clickable(enabled = !running) { attachments.remove(name)?.delete() },
                    ) {
                        Text(
                            "$name ✕",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
        if (attachments.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "The agent may read attached files",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = fsReadGranted,
                    onCheckedChange = { granted ->
                        fsReadGranted = granted
                        consent.setGranted("fs.read", granted)
                    },
                )
            }
        }

        // The workspace: grant/revoke the ONE folder the agent may organize, plus the grouped
        // consent switch (one visible gesture sets the four fs.* grants; every write still needs
        // its per-run approval above) and the undo journal's counter-button.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = { pickWorkspace.launch(null) }, enabled = !running) {
                Text(if (workspaceTree == null) "Grant a folder" else "Folder: ${workspaceTree?.name() ?: "(gone)"}")
            }
            if (workspaceTree != null) {
                TextButton(onClick = {
                    workspacePrefs.edit().remove("workspace.treeUri").apply()
                    workspaceTree = null
                }, enabled = !running) { Text("Revoke") }
            }
            Spacer(Modifier.weight(1f))
            if (undoCount > 0) {
                TextButton(onClick = {
                    undoNotice = undoJournal.undoLast()
                    undoCount = undoJournal.count
                }, enabled = !running) { Text("Undo last move ($undoCount)") }
            }
        }
        if (workspaceTree != null) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "The agent may organize the workspace folder",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = workspaceGranted,
                    onCheckedChange = { granted ->
                        workspaceGranted = granted
                        listOf("fs.list", "fs.move", "fs.rename", "fs.trash").forEach { consent.setGranted(it, granted) }
                    },
                )
            }
        }
        undoNotice?.let { notice ->
            Text(
                notice,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            )
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
            // Export the completed run as a Markdown walkthrough — shown only once a run has finished,
            // mirroring chat's Share. The agent's reasoning leaves the device on the user's terms.
            if (!running && haltReason != null) {
                TextButton(onClick = {
                    session.exportMarkdown()?.let { md ->
                        val share = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, "Quenderin agent run")
                            putExtra(Intent.EXTRA_TEXT, md)
                        }
                        runCatching { context.startActivity(Intent.createChooser(share, "Share walkthrough")) }
                    }
                }) { Text("Share") }
                Spacer(Modifier.width(8.dp))
            }
            if (running) {
                // The kill switch: end the run at the next step boundary AND release a blocked
                // approval question as a decline (a stop must never leave a thread waiting on a
                // dialog nobody will answer).
                TextButton(onClick = {
                    session.cancel()
                    broker.cancelPending()
                }) { Text("Stop") }
            }
            Button(
                enabled = !running && goal.isNotBlank(),
                onClick = {
                    val g = goal.trim()
                    goal = ""
                    // Recorded at SUBMIT, not completion (twin of iOS): a cancelled or halted
                    // goal is still one the user typed and may want back.
                    recentGoals = goalHistory.record(g)
                    // Set running synchronously on the calling (main) thread so a rapid
                    // double-tap can't enqueue a second run before IO flips the flag.
                    running = true
                    scope.launch(Dispatchers.IO) { session.run(g) }
                },
            ) { Text("Run") }
        }
    }

    // The per-run approval dialog — the heart of the trust loop (twin of the iOS AgentView
    // dialog and the dashboard's modal). Dismissing without answering counts as NO.
    pendingApproval?.let { preview ->
        AlertDialog(
            onDismissRequest = {
                pendingApproval = null
                broker.answer(false)
            },
            title = { Text("Allow this action?") },
            text = { Text("${preview.summary}\n\nNothing runs without your yes. Dismissing counts as no.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingApproval = null
                    broker.answer(true)
                }) { Text("Allow") }
            },
            dismissButton = {
                TextButton(onClick = {
                    pendingApproval = null
                    broker.answer(false)
                }) { Text("Don't allow") }
            },
        )
    }
}

/**
 * The live "the agent is working" row — a spinner, which step it's on, and (on the first step)
 * an honest expectation that on-device planning takes a moment. Present whenever a run is in
 * flight so the screen can never read as frozen. Compose twin of iOS `AgentWorkingRow`.
 */
@Composable
private fun AgentWorkingRow(stepNumber: Int, firstStep: Boolean) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(12.dp).semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(10.dp))
            Column {
                Text(
                    if (firstStep) "Planning the task…" else "Working on step $stepNumber…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                if (firstStep) {
                    Text(
                        "The model is thinking on-device — the first step takes the longest.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
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
        Row(
            Modifier.padding(12.dp).semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.Top,
        ) {
            // Decorative alert glyph — hidden from TalkBack so the message is read once, not "warning sign".
            Text("⚠️", modifier = Modifier.clearAndSetSemantics {})
            Spacer(Modifier.width(8.dp))
            Text(message, color = MaterialTheme.colorScheme.onErrorContainer)
        }
    }
}

/**
 * First-run guidance, centered in the transcript area (twin of chat's centered empty state) with an
 * on-brand spark focal point so the screen reads as intentional rather than a top-stuck note over a
 * big empty middle. The examples are deliberately MULTI-STEP — each needs the agent to plan and chain
 * more than one tool (convert → calculate, date → divide), showcasing agentic work instead of a
 * single-shot calculation.
 */
@OptIn(ExperimentalFoundationApi::class)   // combinedClickable (tap = re-use, long-press = remove)
@Composable
private fun AgentEmptyState(
    modifier: Modifier = Modifier,
    onPick: (String) -> Unit = {},
    recents: List<AgentGoalEntry> = emptyList(),
    onRemoveRecent: (String) -> Unit = {},
    onClearRecents: () -> Unit = {},
) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        AgentSparkGlyph()
        Spacer(Modifier.height(16.dp))
        Text(
            "Give the agent a multi-step goal",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "It plans, calls tools, and chains the results.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(22.dp))
        // Examples as a left-aligned list, but the block itself is centered horizontally.
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            listOf(
                "Convert 5 miles to km, then take 20% of that",
                "Days until 2027-01-01 — and how many weeks?",
                "18% of 240, then convert that many km to miles",
            ).forEach { example ->
                // Tapping an example drops it into the goal field, ready to edit or run
                // (twin of the iOS empty state).
                Text(
                    "↳ $example",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.clickable { onPick(example) },
                )
            }
        }
        // The user's own past goals, newest first — tap to re-use (drops into the field, ready
        // to edit or run again), long-press to remove one, one button to forget all. Twin of iOS
        // AgentRecentGoals; rendered only on the empty state — once a run is on screen, the
        // transcript owns the space.
        if (recents.isNotEmpty()) {
            Spacer(Modifier.height(22.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "RECENT GOALS",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                recents.forEach { entry ->
                    Text(
                        "↺ ${entry.goal}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .combinedClickable(
                                onClick = { onPick(entry.goal) },
                                onLongClick = { onRemoveRecent(entry.goal) },
                            )
                            .semantics {
                                customActions = listOf(
                                    CustomAccessibilityAction("Remove from recents") {
                                        onRemoveRecent(entry.goal); true
                                    },
                                )
                            },
                    )
                }
                Text(
                    "Clear recent goals",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.clickable { onClearRecents() },
                )
            }
        }
    }
}

/** The 4-point "AI spark" — the filled twin of the Agent nav icon, as the empty-state focal point. */
@Composable
private fun AgentSparkGlyph() {
    val color = MaterialTheme.colorScheme.primary
    Canvas(Modifier.size(56.dp)) {
        val s = size.minDimension
        val cx = s * 0.5f; val cy = s * 0.5f; val r = s * 0.46f; val k = r * 0.16f
        val p = Path().apply {
            moveTo(cx, cy - r)
            quadraticBezierTo(cx + k, cy - k, cx + r, cy)
            quadraticBezierTo(cx + k, cy + k, cx, cy + r)
            quadraticBezierTo(cx - k, cy + k, cx - r, cy)
            quadraticBezierTo(cx - k, cy - k, cx, cy - r)
            close()
        }
        drawPath(p, color)
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
