package ai.quenderin.app.ui

import ai.quenderin.core.DeskResult
import ai.quenderin.core.DeviceFacts
import ai.quenderin.core.FileModelStorage
import ai.quenderin.core.HttpMcp
import ai.quenderin.core.LocalPace
import ai.quenderin.core.LocalToolDesk
import ai.quenderin.core.McpClient
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelManager
import ai.quenderin.core.ModelRole
import ai.quenderin.core.ModelRoleBook
import ai.quenderin.core.OnDeviceCopy
import ai.quenderin.core.PracticeQuestions
import ai.quenderin.core.PerceptionSeat
import ai.quenderin.core.RoleSeat
import ai.quenderin.core.deviceCheckup
import ai.quenderin.core.roleTitle
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal object JobPrefs {
    private const val rolesKey = "onDeviceRoles"
    private const val toolsKey = "onDeviceTools"
    private const val currentKey = "onDeviceCurrent"
    private const val notesKey = "onDeviceNotes"

    private fun prefs(context: Context) = context.getSharedPreferences("quenderin", Context.MODE_PRIVATE)

    fun book(context: Context) = ModelRoleBook.decode(prefs(context).getString(rolesKey, "") ?: "")
    fun save(context: Context, book: ModelRoleBook) {
        prefs(context).edit().putString(rolesKey, book.encode()).apply()
    }
    fun desk(context: Context) = LocalToolDesk.decode(prefs(context).getString(toolsKey, "") ?: "")
    fun save(context: Context, desk: LocalToolDesk) {
        prefs(context).edit().putString(toolsKey, desk.encode()).apply()
    }
    fun setCurrent(context: Context, id: String) {
        prefs(context).edit().putString(currentKey, id).apply()
    }
    fun current(context: Context) = prefs(context).getString(currentKey, null) ?: "new"
    fun rememberNotes(context: Context, notes: Int) {
        prefs(context).edit().putInt(notesKey, notes).apply()
    }
    fun notes(context: Context) = prefs(context).getInt(notesKey, 0)
}

private enum class JobPage { DOCTOR, PRACTICE, TOOLS, PERCEPTION, CHAT, CHECK, PHOTOS }

/**
 * Shown on a blank chat before the first message, and from Settings. The three jobs,
 * the checkup, the practice score, and local tool switches are on this one card.
 */
@Composable
internal fun OnDeviceCard(
    conversationId: String,
    chatModel: ModelEntry,
    guidanceNotes: Int,
    skillCount: Int,
    onSelectChat: (ModelEntry) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    remember { ai.quenderin.app.BuiltinToolPrefs.load(context) }
    val scope = rememberCoroutineScope()
    val book = remember { JobPrefs.book(context) }
    val desk = remember { JobPrefs.desk(context) }
    var revision by remember { mutableIntStateOf(0) }
    var page by remember { mutableStateOf<JobPage?>(null) }
    var checkup by remember { mutableStateOf<ai.quenderin.core.Checkup?>(null) }
    var practice by remember { mutableStateOf<ai.quenderin.core.PracticeScore?>(null) }
    var serverName by remember { mutableStateOf("") }
    var serverAddress by remember { mutableStateOf("") }
    var toolNote by remember { mutableStateOf("") }
    var perceptionNote by remember { mutableStateOf("") }
    val installed = remember(chatModel.id) {
        val dir = java.io.File(context.filesDir, "models")
        runCatching { ModelManager(FileModelStorage(dir), chatModel.id).installed().map { it.model } }.getOrDefault(emptyList())
    }
    val tick = revision
    val roles = if (tick >= 0) book.roles(conversationId, chatModel.id) else book.roles(conversationId, chatModel.id)
    val names = remember(installed, chatModel.id, revision) {
        installed.associate { it.id to it.label } + (chatModel.id to chatModel.label)
    }
    LaunchedEffect(conversationId, revision, guidanceNotes) {
        JobPrefs.setCurrent(context, conversationId)
        JobPrefs.rememberNotes(context, guidanceNotes)
        val current = book.roles(conversationId, chatModel.id)
        RoleSeat.selectChecker(current.checkerModelId)
        if (!RoleSeat.perceptionOpen) RoleSeat.perceptionModelId = current.perceptionModelId
    }
    fun refresh() { revision += 1 }
    fun assign(role: ModelRole, modelId: String?) {
        book.assign(conversationId, role, modelId, chatModel.id)
        JobPrefs.save(context, book)
        refresh()
        page = if (role == ModelRole.PERCEPTION) JobPage.PERCEPTION else null
    }

    Surface(
        modifier.fillMaxWidth().testTag("onDevice.card"),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(OnDeviceCopy.TITLE, style = MaterialTheme.typography.titleMedium)
            RoleLine("Chat", roleTitle(ModelRole.CHAT, roles, names)) { page = JobPage.CHAT }
            RoleLine("Check", roleTitle(ModelRole.CHECKER, roles, names)) { page = JobPage.CHECK }
            RoleLine(OnDeviceCopy.PHOTOS, roleTitle(ModelRole.PERCEPTION, roles, names)) { page = JobPage.PHOTOS }
            Text(OnDeviceCopy.CARD, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(OnDeviceCopy.CHECKER_RUNS, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { page = JobPage.DOCTOR }, modifier = Modifier.weight(1f)) { Text(OnDeviceCopy.DOCTOR_BUTTON) }
                OutlinedButton(onClick = { page = JobPage.PRACTICE }, modifier = Modifier.weight(1f)) { Text(OnDeviceCopy.PRACTICE_BUTTON) }
                OutlinedButton(onClick = { page = JobPage.TOOLS }, modifier = Modifier.weight(1f)) { Text(OnDeviceCopy.TOOLS_BUTTON) }
            }
        }
    }

    if (page != null) {
        AlertDialog(
            onDismissRequest = {
                if (page == JobPage.PERCEPTION) PerceptionSeat.close()
                page = null
            },
            confirmButton = { TextButton(onClick = {
                if (page == JobPage.PERCEPTION) PerceptionSeat.close()
                page = null
            }) { Text("Done") } },
            title = { Text(when (page) {
                JobPage.DOCTOR -> OnDeviceCopy.DOCTOR_BUTTON
                JobPage.PRACTICE -> OnDeviceCopy.PRACTICE_BUTTON
                JobPage.TOOLS -> OnDeviceCopy.TOOLS_BUTTON
                JobPage.PERCEPTION, JobPage.PHOTOS -> OnDeviceCopy.PHOTOS
                JobPage.CHECK -> "Check"
                else -> "Chat"
            }) },
            text = {
                Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    when (page) {
                        JobPage.CHAT, JobPage.CHECK, JobPage.PHOTOS -> {
                            val role = when (page) {
                                JobPage.CHECK -> ModelRole.CHECKER
                                JobPage.PHOTOS -> ModelRole.PERCEPTION
                                else -> ModelRole.CHAT
                            }
                            if (role != ModelRole.CHAT) {
                                TextButton(onClick = { assign(role, null) }) {
                                    Text(if (role == ModelRole.CHECKER) OnDeviceCopy.SHAPE else OnDeviceCopy.NOT_LOADED)
                                }
                            }
                            if (installed.isEmpty()) {
                                Text("Only the open chat model is on this device. Nothing will be downloaded.", style = MaterialTheme.typography.bodySmall)
                            }
                            val choices = if (installed.any { it.id == chatModel.id }) installed else listOf(chatModel) + installed
                            choices.forEach { entry ->
                                TextButton(onClick = {
                                    if (role == ModelRole.CHAT) onSelectChat(entry)
                                    assign(role, entry.id)
                                }) { Text(entry.label) }
                            }
                            Text(OnDeviceCopy.NOT_INFERENCE, style = MaterialTheme.typography.bodySmall)
                        }
                        JobPage.DOCTOR -> {
                            TextButton(onClick = { checkup = checkupOf(roles, names, installed, chatModel, guidanceNotes, skillCount, desk) }) {
                                Text(OnDeviceCopy.RUN_CHECKUP)
                            }
                            checkup?.let { result ->
                                Text(result.summary, style = MaterialTheme.typography.bodyMedium)
                                result.rows.forEach { row ->
                                    Text(row.name, style = MaterialTheme.typography.labelLarge)
                                    Text(row.detail, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                            Text(OnDeviceCopy.NOT_INFERENCE, style = MaterialTheme.typography.bodySmall)
                        }
                        JobPage.PRACTICE -> {
                            TextButton(onClick = { practice = PracticeQuestions.score() }) { Text(OnDeviceCopy.RUN_PRACTICE) }
                            practice?.let { score ->
                                Text(score.tally, style = MaterialTheme.typography.bodyMedium)
                                Text(score.summary, style = MaterialTheme.typography.bodySmall)
                                score.lines.forEach { line ->
                                    Text(line.prompt, style = MaterialTheme.typography.labelLarge)
                                    Text("${line.outcome}: ${line.detail}", style = MaterialTheme.typography.bodySmall)
                                }
                            }
                            Text(OnDeviceCopy.NOT_INFERENCE, style = MaterialTheme.typography.bodySmall)
                        }
                        JobPage.TOOLS -> {
                            LocalPace.builtinIds.forEach { id ->
                                var on by remember(id, revision) { mutableStateOf(LocalPace.isOn(id)) }
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Text(when (id) {
                                        "calculator" -> "Calculator"
                                        "units" -> "Units"
                                        "date" -> "Dates"
                                        else -> id
                                    }, modifier = Modifier.weight(1f))
                                    Switch(checked = on, onCheckedChange = {
                                        on = it
                                        ai.quenderin.app.BuiltinToolPrefs.set(context, id, it)
                                        refresh()
                                    })
                                }
                            }
                            Text(
                                if (desk.servers.isEmpty()) OnDeviceCopy.NO_SERVERS else "Local servers stay on this device.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                            OutlinedTextField(serverName, { serverName = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(serverAddress, { serverAddress = it }, label = { Text("Local address") }, modifier = Modifier.fillMaxWidth())
                            TextButton(onClick = {
                                when (val added = desk.add(serverName, serverAddress, null, false)) {
                                    is DeskResult.Ok -> {
                                        toolNote = ""
                                        serverName = ""
                                        serverAddress = ""
                                        JobPrefs.save(context, desk)
                                        refresh()
                                    }
                                    is DeskResult.Rejected -> toolNote = added.message
                                }
                            }) { Text("Add") }
                            if (toolNote.isNotEmpty()) Text(toolNote, style = MaterialTheme.typography.bodySmall)
                            desk.servers.forEach { server ->
                                Text(server.name, style = MaterialTheme.typography.labelLarge)
                                TextButton(onClick = {
                                    scope.launch {
                                        val tools = withContext(Dispatchers.IO) {
                                            val address = server.address ?: return@withContext emptyList()
                                            McpClient(HttpMcp(address)).listTools()
                                        }
                                        if (tools.isEmpty()) toolNote = OnDeviceCopy.SERVER_SILENT
                                        else {
                                            desk.remember(server.id, tools)
                                            toolNote = ""
                                            JobPrefs.save(context, desk)
                                            refresh()
                                        }
                                    }
                                }) { Text(OnDeviceCopy.LOOK_UP) }
                                desk.toolsOf(server.id).forEach { tool ->
                                    var on by remember(server.id, tool.name, revision) { mutableStateOf(desk.isOn(server.id, tool.name)) }
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(tool.title, modifier = Modifier.weight(1f))
                                        Switch(checked = on, onCheckedChange = {
                                            on = it
                                            desk.setOn(server.id, tool.name, it)
                                            JobPrefs.save(context, desk)
                                            refresh()
                                        })
                                    }
                                }
                            }
                        }
                        JobPage.PERCEPTION -> {
                            Text(roleTitle(ModelRole.PERCEPTION, roles, names), style = MaterialTheme.typography.bodyMedium)
                            Text("This screen is the only place photos and speech load. Chat did not load them.", style = MaterialTheme.typography.bodySmall)
                            TextButton(onClick = {
                                PerceptionSeat.open(roles.perceptionModelId)
                                perceptionNote = PerceptionSeat.look("sample")
                            }) { Text(OnDeviceCopy.LOOK) }
                            TextButton(onClick = {
                                PerceptionSeat.open(roles.perceptionModelId)
                                perceptionNote = PerceptionSeat.listen("clip")
                            }) { Text(OnDeviceCopy.LISTEN) }
                            if (perceptionNote.isNotEmpty()) Text(perceptionNote, style = MaterialTheme.typography.bodySmall)
                            Text(OnDeviceCopy.NOT_INFERENCE, style = MaterialTheme.typography.bodySmall)
                        }
                        null -> Unit
                    }
                }
            },
        )
    }
}

@Composable
private fun RoleLine(label: String, value: String, onChange: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 40.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(0.9f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1.4f))
        TextButton(onClick = onChange) { Text(OnDeviceCopy.CHANGE) }
    }
}

private fun checkupOf(
    roles: ai.quenderin.core.ConversationRoles,
    names: Map<String, String>,
    installed: List<ModelEntry>,
    chatModel: ModelEntry,
    guidanceNotes: Int,
    skillCount: Int,
    desk: LocalToolDesk,
) = deviceCheckup(DeviceFacts(
    chatModelId = roles.chatModelId,
    chatLabel = names[roles.chatModelId] ?: roles.chatModelId,
    chatOnDevice = installed.any { it.id == roles.chatModelId } || roles.chatModelId == chatModel.id,
    checkerModelId = roles.checkerModelId,
    checkerOnDevice = roles.checkerModelId?.let { id -> installed.any { it.id == id } } ?: false,
    perceptionModelId = roles.perceptionModelId,
    perceptionOnDevice = roles.perceptionModelId?.let { id -> installed.any { it.id == id } } ?: false,
    perceptionOpen = false,
    guidanceNotes = guidanceNotes,
    guidanceReadable = true,
    skillCount = skillCount,
    skillsReadable = true,
    builtinOn = LocalPace.builtinIds.associateWith { LocalPace.isOn(it) },
    serverCount = desk.servers.size,
    toolsOff = desk.offNames(),
))
