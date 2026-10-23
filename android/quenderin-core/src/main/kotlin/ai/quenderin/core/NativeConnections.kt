package ai.quenderin.core

import java.net.InetAddress
import java.util.Collections
import java.util.Locale

/** Foundation only. These values do not open a connection, read credentials, or execute tools. */
object NativeConnectionBounds {
    const val MAX_ENVELOPE_BYTES = 8_388_608
    const val MAX_MESSAGES = 1_024
    const val MAX_TEXT_BYTES = 1_048_576
    const val MAX_TOOL_CALLS = 128
    const val MAX_DOCUMENTS = 32
    const val MAX_PENDING = 128
    const val MAX_JSON_DEPTH = 32
    const val MAX_COUNTER = 9_007_199_254_740_991L
}

/** Stable error codes only: input, content, credentials and remote diagnostics never enter errors. */
class NativeConnectionException(val code: String) : IllegalArgumentException("Native connections: $code")

internal fun connectionCheck(condition: Boolean, code: String = "invalid-field") {
    if (!condition) throw NativeConnectionException(code)
}

private val connectionIdentifier = Regex("^[A-Za-z0-9._-]{1,128}$")
private val connectionCredential = Regex("^qcred:[A-Za-z0-9._-]{1,128}$")
private val connectionDigest = Regex("^[a-f0-9]{64}$")
private fun identifier(value: String) = connectionCheck(connectionIdentifier.matches(value), "invalid-identifier")
private fun digest(value: String) = connectionCheck(connectionDigest.matches(value), "invalid-digest")
private fun counter(value: Long) = connectionCheck(value in 0..NativeConnectionBounds.MAX_COUNTER, "invalid-counter")
private fun text(value: String, nonempty: Boolean = false) {
    connectionCheck(!nonempty || value.isNotEmpty(), "empty-text")
    validateUnicode(value)
    connectionCheck(value.toByteArray(Charsets.UTF_8).size <= NativeConnectionBounds.MAX_TEXT_BYTES, "text-limit")
}
private fun validateUnicode(value: String) {
    var i = 0
    while (i < value.length) {
        val c = value[i++]
        if (c.isHighSurrogate()) {
            connectionCheck(i < value.length && value[i].isLowSurrogate(), "invalid-unicode")
            i++
        } else connectionCheck(!c.isLowSurrogate(), "invalid-unicode")
    }
}
private fun <T> snapshot(values: List<T>): List<T> = Collections.unmodifiableList(ArrayList(values))
private fun <T> unique(values: List<T>, key: (T) -> String) =
    connectionCheck(values.map(key).toSet().size == values.size, "duplicate-id")

/** Lower-bound payload accounting before any aggregate JSON tree/string is built. */
private class ConnectionWireSizeBudget {
    private var remaining = NativeConnectionBounds.MAX_ENVELOPE_BYTES
    fun include(value: String?) {
        if (value == null) return
        val bytes = value.toByteArray(Charsets.UTF_8).size
        connectionCheck(bytes <= remaining, "envelope-limit")
        remaining -= bytes
    }
}

/** ASCII HTTPS origins only; no DNS lookup, redirect, userinfo, path, query or fragment. */
object ConnectionOrigins {
    fun canonicalize(value: String): String {
        connectionCheck(value.length <= 2_048 && value.all { it.code in 33..126 }, "invalid-origin")
        connectionCheck(value.length >= 8 && value.substring(0, 8).equals("https://", true), "invalid-origin")
        var authority = value.substring(8)
        if (authority.endsWith('/')) authority = authority.dropLast(1)
        connectionCheck(authority.isNotEmpty() && authority.none { it in "/\\@?#%" }, "invalid-origin")
        val host: String
        val portText: String?
        if (authority.startsWith('[')) {
            val close = authority.indexOf(']')
            connectionCheck(close > 1, "invalid-origin")
            val literal = authority.substring(1, close)
            connectionCheck(literal.length <= 45 && ':' in literal && literal.all { it in "0123456789abcdefABCDEF:." }, "invalid-origin")
            if ('.' in literal) {
                val octets = literal.substringAfterLast(':').split('.')
                connectionCheck(octets.size == 4 && octets.all { it.toIntOrNull() in 0..255 && (it.length == 1 || !it.startsWith('0')) }, "invalid-origin")
            }
            // A colon-containing, character-gated literal cannot trigger a DNS lookup. Zones are rejected above.
            connectionCheck(runCatching { InetAddress.getByName(literal) }.isSuccess, "invalid-origin")
            host = "[${literal.lowercase(Locale.ROOT)}]"
            val tail = authority.substring(close + 1)
            connectionCheck(tail.isEmpty() || tail.startsWith(':'), "invalid-origin")
            portText = if (tail.isEmpty()) null else tail.substring(1)
        } else {
            connectionCheck(authority.count { it == ':' } <= 1, "invalid-origin")
            host = authority.substringBefore(':').lowercase(Locale.ROOT)
            portText = if (':' in authority) authority.substringAfter(':') else null
            connectionCheck(host.length in 1..253, "invalid-origin")
            connectionCheck(host.split('.').all { label ->
                label.length in 1..63 && label.first().isLetterOrDigit() && label.last().isLetterOrDigit() &&
                    label.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }
            }, "invalid-origin")
            if (host.all { it in '0'..'9' || it == '.' }) {
                val components = host.split('.')
                connectionCheck(components.size == 4 && components.all { it.toIntOrNull() in 0..255 && (it.length == 1 || !it.startsWith('0')) }, "invalid-origin")
            }
        }
        val port = portText?.let {
            connectionCheck(it.isNotEmpty() && it.length <= 5 && it.all { c -> c in '0'..'9' }, "invalid-origin")
            it.toIntOrNull().also { number -> connectionCheck(number != null && number in 1..65_535, "invalid-origin") }
        }
        return "https://$host" + if (port == null || port == 443) "" else ":$port"
    }
}

enum class ConnectionKind(val wire: String) { LOCAL("local"), DEEPSEEK("deepseek"), REMOTE_HARNESS("remoteHarness") }
enum class ProviderRole(val wire: String) { SYSTEM("system"), USER("user"), ASSISTANT("assistant"), TOOL("tool") }
enum class ReasoningEffort(val wire: String) { OFF("off"), LOW("low"), HIGH("high"), MAX("max") }

data class ConnectionProfile(
    val id: String, val kind: ConnectionKind, val displayName: String,
    val endpoint: String?, val credentialReference: String?, val hostID: String?,
    val hostFingerprint: String?, val workspaceID: String?,
) {
    init {
        identifier(id); text(displayName, true); connectionCheck(!displayName.isBlank(), "empty-text")
        credentialReference?.let { connectionCheck(connectionCredential.matches(it), "invalid-credential-reference") }
        validateDestination(kind, endpoint, hostID, hostFingerprint, workspaceID)
        if (kind == ConnectionKind.LOCAL) connectionCheck(credentialReference == null, "invalid-destination")
    }
    override fun toString() = "ConnectionProfile(redacted)"
    companion object {
        fun create(id: String, kind: ConnectionKind, displayName: String, endpoint: String? = null,
                   credentialReference: String? = null, hostID: String? = null, hostFingerprint: String? = null,
                   workspaceID: String? = null) = ConnectionProfile(id, kind, displayName,
            endpoint?.let(ConnectionOrigins::canonicalize), credentialReference, hostID, hostFingerprint, workspaceID)
        fun localDefault() = create("local-default", ConnectionKind.LOCAL, "On this device")
    }
}

private fun validateDestination(kind: ConnectionKind, origin: String?, hostID: String?, fingerprint: String?, workspaceID: String?) {
    origin?.let { connectionCheck(it == ConnectionOrigins.canonicalize(it), "noncanonical-origin") }
    when (kind) {
        ConnectionKind.LOCAL -> connectionCheck(origin == null && hostID == null && fingerprint == null && workspaceID == null, "invalid-destination")
        ConnectionKind.DEEPSEEK -> connectionCheck(origin == "https://api.deepseek.com" && hostID == null && fingerprint == null && workspaceID == null, "invalid-destination")
        ConnectionKind.REMOTE_HARNESS -> {
            connectionCheck(origin != null && hostID != null && fingerprint != null && workspaceID != null, "invalid-destination")
            identifier(hostID!!); digest(fingerprint!!); identifier(workspaceID!!)
        }
    }
}

data class ConversationBinding(
    val profileID: String, val kind: ConnectionKind, val origin: String?, val hostID: String?,
    val hostFingerprint: String?, val workspaceID: String?,
) {
    init { identifier(profileID); validateDestination(kind, origin, hostID, hostFingerprint, workspaceID) }
    fun requireMatches(profile: ConnectionProfile) = connectionCheck(this == from(profile), "binding-mismatch")
    override fun toString() = "ConversationBinding(redacted)"
    companion object {
        fun create(profileID: String, kind: ConnectionKind, origin: String? = null, hostID: String? = null,
                   hostFingerprint: String? = null, workspaceID: String? = null) = ConversationBinding(
            profileID, kind, origin?.let(ConnectionOrigins::canonicalize), hostID, hostFingerprint, workspaceID)
        fun from(profile: ConnectionProfile) = create(profile.id, profile.kind, profile.endpoint, profile.hostID, profile.hostFingerprint, profile.workspaceID)
    }
}

/** Ephemeral authenticated transport scope; never serialized into conversation history.
 * A discovery scope references a local enrollment draft, not a persisted profile/workspace. */
data class RemoteHarnessTransportBinding(
    val scopeReference: String, val origin: String, val hostID: String,
    val hostFingerprint: String, val workspaceID: String? = null,
) {
    init {
        identifier(scopeReference); identifier(hostID); digest(hostFingerprint)
        connectionCheck(origin == ConnectionOrigins.canonicalize(origin), "noncanonical-origin")
        workspaceID?.let(::identifier)
    }
    override fun toString() = "RemoteHarnessTransportBinding(redacted)"
    companion object {
        fun discovery(enrollmentDraftID: String, origin: String, hostID: String, hostFingerprint: String) =
            RemoteHarnessTransportBinding(enrollmentDraftID, ConnectionOrigins.canonicalize(origin), hostID, hostFingerprint)
        fun from(binding: ConversationBinding): RemoteHarnessTransportBinding {
            connectionCheck(binding.kind == ConnectionKind.REMOTE_HARNESS, "invalid-binding")
            return RemoteHarnessTransportBinding(binding.profileID, binding.origin!!, binding.hostID!!,
                binding.hostFingerprint!!, binding.workspaceID)
        }
    }
}

data class ProviderSelection(val providerID: String, val modelID: String, val reasoningEffort: ReasoningEffort) {
    init { identifier(providerID); identifier(modelID) }
    override fun toString() = "ProviderSelection(redacted)"
}
data class ProviderDocument(val name: String, val text: String) {
    init { text(name); text(text) }
    override fun toString() = "ProviderDocument(redacted)"
}
data class ProviderToolCall(val id: String, val name: String, val argumentsJSON: String) {
    init { identifier(id); identifier(name); text(argumentsJSON) }
    override fun toString() = "ProviderToolCall(redacted)"
}

/** Snapshot lists at construction so caller mutation cannot invalidate a validated request. */
class ProviderMessage(
    val id: String, val role: ProviderRole, val content: String, val reasoningContent: String? = null,
    toolCalls: List<ProviderToolCall> = emptyList(), val toolCallID: String? = null,
    documents: List<ProviderDocument> = emptyList(),
) {
    val toolCalls = snapshot(toolCalls)
    val documents = snapshot(documents)
    init {
        identifier(id); text(content); reasoningContent?.let { text(it) }
        connectionCheck(toolCalls.size <= NativeConnectionBounds.MAX_TOOL_CALLS && documents.size <= NativeConnectionBounds.MAX_DOCUMENTS, "array-limit")
        unique(toolCalls) { it.id }
        connectionCheck(role == ProviderRole.ASSISTANT || (reasoningContent == null && toolCalls.isEmpty()), "invalid-message-role")
        if (role == ProviderRole.TOOL) { connectionCheck(toolCallID != null, "invalid-message-role"); identifier(toolCallID!!) }
        else connectionCheck(toolCallID == null, "invalid-message-role")
        connectionCheck(role == ProviderRole.USER || documents.isEmpty(), "invalid-message-role")
    }
    override fun toString() = "ProviderMessage(redacted)"
}

enum class RemoteSessionStatus(val wire: String) {
    DISCONNECTED("disconnected"), CONNECTING("connecting"), READY("ready"), RUNNING("running"),
    AWAITING_APPROVAL("awaitingApproval"), STOP_REQUESTED("stopRequested"), STOPPED("stopped"), OUTCOME_UNKNOWN("outcomeUnknown")
}
enum class RemoteCommandKind(val wire: String) { SEND("send"), APPROVE("approve"), DENY("deny"), STOP("stop") }
enum class RemoteCommandState(val wire: String) { PREPARED("prepared"), SENT("sent"), ACKNOWLEDGED("acknowledged"), OUTCOME_UNKNOWN("outcomeUnknown") }
enum class ApprovalDecision { APPROVE, DENY }

data class RemoteIdentity(val hostID: String, val deviceID: String, val workspaceID: String, val sessionID: String, val runID: String? = null) {
    init { identifier(hostID); identifier(deviceID); identifier(workspaceID); identifier(sessionID); runID?.let(::identifier) }
    override fun toString() = "RemoteIdentity(redacted)"
}
data class PendingRemoteCommand(val requestID: String, val kind: RemoteCommandKind, val state: RemoteCommandState) {
    init { identifier(requestID) }
    override fun toString() = "PendingRemoteCommand(redacted)"
}
data class PendingRemoteApproval(
    val approvalID: String, val requestID: String, val hostID: String, val deviceID: String,
    val workspaceID: String, val sessionID: String, val runID: String,
    val actionDigest: String, val expiresAtEpochMs: Long,
) {
    init { identifier(approvalID); identifier(requestID); identity(); digest(actionDigest); counter(expiresAtEpochMs) }
    fun identity() = RemoteIdentity(hostID, deviceID, workspaceID, sessionID, runID)
    override fun toString() = "PendingRemoteApproval(redacted)"
}

/** Immutable recovery state. No transition replays a mutation or treats disconnect as successful stop. */
class RemoteSessionState(
    val hostID: String, val deviceID: String, val workspaceID: String, val sessionID: String,
    val status: RemoteSessionStatus, pendingCommands: List<PendingRemoteCommand> = emptyList(),
    pendingApprovals: List<PendingRemoteApproval> = emptyList(), val runID: String? = null,
    val lastConfirmedEventID: String? = null,
) {
    val pendingCommands = snapshot(pendingCommands)
    val pendingApprovals = snapshot(pendingApprovals)
    init {
        identity(); lastConfirmedEventID?.let { text(it, true) }
        connectionCheck(pendingCommands.size <= NativeConnectionBounds.MAX_PENDING && pendingApprovals.size <= NativeConnectionBounds.MAX_PENDING, "array-limit")
        unique(pendingCommands) { it.requestID }; unique(pendingApprovals) { it.approvalID }
        pendingApprovals.forEach { connectionCheck(it.identity() == identity(), "approval-identity-mismatch") }
    }
    fun identity() = RemoteIdentity(hostID, deviceID, workspaceID, sessionID, runID)
    fun requireIdentity(expected: RemoteIdentity) = connectionCheck(identity() == expected, "session-identity-mismatch")
    fun requireBinding(binding: ConversationBinding) = connectionCheck(
        binding.kind == ConnectionKind.REMOTE_HARNESS && hostID == binding.hostID && workspaceID == binding.workspaceID,
        "session-binding-mismatch")

    fun prepare(requestID: String, kind: RemoteCommandKind): RemoteSessionState {
        connectionCheck(kind == RemoteCommandKind.SEND || kind == RemoteCommandKind.STOP, "approval-required")
        connectionCheck(status in setOf(RemoteSessionStatus.READY, RemoteSessionStatus.RUNNING, RemoteSessionStatus.AWAITING_APPROVAL), "session-not-ready")
        connectionCheck(pendingCommands.none { it.requestID == requestID }, "duplicate-id")
        return replace(status = if (kind == RemoteCommandKind.STOP) RemoteSessionStatus.STOP_REQUESTED else status,
            commands = pendingCommands + PendingRemoteCommand(requestID, kind, RemoteCommandState.PREPARED))
    }

    /** Caller must persist the returned snapshot before attempting the external send. */
    fun markSent(requestID: String, expected: RemoteIdentity): RemoteSessionState {
        requireIdentity(expected)
        connectionCheck(status !in setOf(RemoteSessionStatus.DISCONNECTED, RemoteSessionStatus.CONNECTING, RemoteSessionStatus.STOPPED, RemoteSessionStatus.OUTCOME_UNKNOWN), "session-not-ready")
        val command = command(requestID)
        connectionCheck(status != RemoteSessionStatus.STOP_REQUESTED || command.kind == RemoteCommandKind.STOP, "stop-in-progress")
        connectionCheck(command.state == RemoteCommandState.PREPARED, "command-not-prepared")
        val nextStatus = if (command.kind == RemoteCommandKind.STOP) RemoteSessionStatus.STOP_REQUESTED
            else if (pendingApprovals.isEmpty()) RemoteSessionStatus.RUNNING else RemoteSessionStatus.AWAITING_APPROVAL
        return replace(status = nextStatus, commands = pendingCommands.map { if (it.requestID == requestID) it.copy(state = RemoteCommandState.SENT) else it })
    }

    /** Unknown outcomes can be reconciled by a matching authoritative acknowledgement, never retried here. */
    fun acknowledge(requestID: String, expected: RemoteIdentity, confirmedEventID: String): RemoteSessionState {
        requireIdentity(expected); text(confirmedEventID, true)
        val command = command(requestID)
        connectionCheck(command.state == RemoteCommandState.SENT || command.state == RemoteCommandState.OUTCOME_UNKNOWN, "command-not-sent")
        return replace(status = if (command.kind == RemoteCommandKind.STOP) RemoteSessionStatus.STOPPED else status,
            commands = pendingCommands.map { if (it.requestID == requestID) it.copy(state = RemoteCommandState.ACKNOWLEDGED) else it }, eventID = confirmedEventID)
    }

    fun disconnected(): RemoteSessionState {
        val uncertain = pendingCommands.any { it.state == RemoteCommandState.SENT || it.state == RemoteCommandState.OUTCOME_UNKNOWN } ||
            status in setOf(RemoteSessionStatus.STOP_REQUESTED, RemoteSessionStatus.OUTCOME_UNKNOWN, RemoteSessionStatus.RUNNING, RemoteSessionStatus.AWAITING_APPROVAL)
        return replace(status = if (status == RemoteSessionStatus.STOPPED) RemoteSessionStatus.STOPPED
            else if (uncertain) RemoteSessionStatus.OUTCOME_UNKNOWN else RemoteSessionStatus.DISCONNECTED,
            commands = pendingCommands.map { if (it.state == RemoteCommandState.SENT) it.copy(state = RemoteCommandState.OUTCOME_UNKNOWN) else it })
    }

    /** Match the complete displayed action, including request and expiry, then consume it before send. */
    fun consumeApproval(expectedApproval: PendingRemoteApproval, expected: RemoteIdentity, nowEpochMs: Long,
                        decision: ApprovalDecision, decisionRequestID: String): RemoteSessionState {
        requireIdentity(expected); counter(nowEpochMs); identifier(decisionRequestID)
        connectionCheck(status == RemoteSessionStatus.AWAITING_APPROVAL, "session-not-awaiting-approval")
        val approval = pendingApprovals.singleOrNull { it.approvalID == expectedApproval.approvalID } ?: throw NativeConnectionException("approval-unavailable")
        connectionCheck(approval == expectedApproval && approval.identity() == expected, "approval-mismatch")
        connectionCheck(nowEpochMs < approval.expiresAtEpochMs, "approval-expired")
        connectionCheck(pendingCommands.none { it.requestID == decisionRequestID }, "duplicate-id")
        return replace(commands = pendingCommands + PendingRemoteCommand(decisionRequestID,
            if (decision == ApprovalDecision.APPROVE) RemoteCommandKind.APPROVE else RemoteCommandKind.DENY, RemoteCommandState.PREPARED),
            approvals = pendingApprovals.filterNot { it.approvalID == expectedApproval.approvalID })
    }

    private fun command(requestID: String) = pendingCommands.singleOrNull { it.requestID == requestID }
        ?: throw NativeConnectionException("command-unavailable")
    private fun replace(status: RemoteSessionStatus = this.status, commands: List<PendingRemoteCommand> = pendingCommands,
                        approvals: List<PendingRemoteApproval> = pendingApprovals, eventID: String? = lastConfirmedEventID) =
        RemoteSessionState(hostID, deviceID, workspaceID, sessionID, status, commands, approvals, runID, eventID)
    override fun toString() = "RemoteSessionState(redacted)"
}

class ConversationEnvelope(
    val conversationID: String, val binding: ConversationBinding, messages: List<ProviderMessage>,
    val selection: ProviderSelection? = null, val remoteSession: RemoteSessionState? = null,
) {
    val messages = snapshot(messages)
    val schemaVersion: Int get() = 1
    init {
        identifier(conversationID); connectionCheck(messages.size <= NativeConnectionBounds.MAX_MESSAGES, "array-limit")
        unique(messages) { it.id }; remoteSession?.requireBinding(binding)
        val budget = ConnectionWireSizeBudget()
        listOf(conversationID, binding.profileID, binding.origin, binding.hostID, binding.hostFingerprint, binding.workspaceID,
            selection?.providerID, selection?.modelID).forEach(budget::include)
        for (message in this.messages) {
            listOf(message.id, message.content, message.reasoningContent, message.toolCallID).forEach(budget::include)
            for (call in message.toolCalls) listOf(call.id, call.name, call.argumentsJSON).forEach(budget::include)
            for (document in message.documents) { budget.include(document.name); budget.include(document.text) }
        }
        remoteSession?.let { session ->
            listOf(session.hostID, session.deviceID, session.workspaceID, session.sessionID, session.runID, session.lastConfirmedEventID).forEach(budget::include)
            session.pendingCommands.forEach { budget.include(it.requestID) }
            session.pendingApprovals.forEach { approval ->
                listOf(approval.approvalID, approval.requestID, approval.hostID, approval.deviceID, approval.workspaceID,
                    approval.sessionID, approval.runID, approval.actionDigest).forEach(budget::include)
            }
        }
    }
    fun requireDispatch(profile: ConnectionProfile) = binding.requireMatches(profile)
    override fun toString() = "ConversationEnvelope(redacted)"
}

data class ProviderCapabilities(val reasoning: Boolean, val toolCalls: Boolean, val documents: Boolean,
                                val cancellation: Boolean, val usage: Boolean) {
    override fun toString() = "ProviderCapabilities"
}
data class ProviderToolDefinition(val name: String, val description: String, val parametersJSON: String) {
    init { identifier(name); text(description); text(parametersJSON); connectionCheck(ConnectionJSON.parse(parametersJSON) is ConnectionJSON.ObjectValue, "invalid-tool-schema") }
    override fun toString() = "ProviderToolDefinition(redacted)"
}
data class ProviderRequestLimits(val maxOutputTokens: Long, val maxToolCalls: Int, val deadlineEpochMs: Long) {
    init {
        counter(maxOutputTokens); connectionCheck(maxOutputTokens > 0, "invalid-limit")
        connectionCheck(maxToolCalls in 0..NativeConnectionBounds.MAX_TOOL_CALLS, "invalid-limit"); counter(deadlineEpochMs)
        connectionCheck(deadlineEpochMs > 0, "invalid-limit")
    }
    override fun toString() = "ProviderRequestLimits"
}
class ProviderRequest(val requestID: String, val envelope: ConversationEnvelope, profile: ConnectionProfile,
                      val capabilities: ProviderCapabilities, tools: List<ProviderToolDefinition>, val limits: ProviderRequestLimits,
                      nowEpochMs: Long) {
    val tools = snapshot(tools)
    val conversationID get() = envelope.conversationID
    val binding get() = envelope.binding
    val messages get() = envelope.messages
    val selection: ProviderSelection = envelope.selection ?: throw NativeConnectionException("selection-required")
    init {
        identifier(requestID); envelope.requireDispatch(profile); counter(nowEpochMs)
        connectionCheck(nowEpochMs < limits.deadlineEpochMs, "deadline-expired")
        connectionCheck(tools.size <= NativeConnectionBounds.MAX_TOOL_CALLS, "array-limit"); unique(tools) { it.name }
        connectionCheck(capabilities.toolCalls || (tools.isEmpty() && messages.none { it.toolCalls.isNotEmpty() || it.role == ProviderRole.TOOL }), "unsupported-capability")
        connectionCheck(capabilities.reasoning || (messages.none { it.reasoningContent != null } && selection.reasoningEffort == ReasoningEffort.OFF), "unsupported-capability")
        connectionCheck(capabilities.documents || messages.none { it.documents.isNotEmpty() }, "unsupported-capability")
        // Include the encoded envelope and tool payloads before a future adapter builds its body.
        val budget = ConnectionWireSizeBudget()
        budget.include(NativeConnectionsCodec.encodeEnvelope(envelope))
        for (tool in this.tools) {
            budget.include(tool.name); budget.include(tool.description); budget.include(tool.parametersJSON)
        }
    }
    override fun toString() = "ProviderRequest(redacted)"
}

enum class ProviderCompletionReason(val wire: String) { END("end"), TOOL_CALLS("toolCalls"), OUTPUT_LIMIT("outputLimit") }
enum class ProviderFailureCode(val wire: String) {
    UNAVAILABLE("unavailable"), UNAUTHORIZED("unauthorized"), RATE_LIMITED("rateLimited"), DEADLINE_EXCEEDED("deadlineExceeded"),
    INVALID_RESPONSE("invalidResponse"), CONNECTION_LOST("connectionLost"), REJECTED("rejected"), LIMIT_EXCEEDED("limitExceeded"), OUTCOME_UNKNOWN("outcomeUnknown")
}
/** Deliberately no raw error/diagnostic field. Tool fragments are data and never executed here. */
sealed class ProviderEvent {
    class Text(val messageID: String, val delta: String) : ProviderEvent() { init { identifier(messageID); text(delta) } }
    class Reasoning(val messageID: String, val delta: String) : ProviderEvent() { init { identifier(messageID); text(delta) } }
    class ToolCallFragment(val messageID: String, val callID: String?, val index: Int, val name: String?, val argumentsDelta: String) : ProviderEvent() {
        init { identifier(messageID); connectionCheck(index in 0 until NativeConnectionBounds.MAX_TOOL_CALLS, "invalid-counter"); callID?.let(::identifier); name?.let(::identifier); text(argumentsDelta) }
    }
    class Usage(val inputTokens: Long, val outputTokens: Long) : ProviderEvent() { init { counter(inputTokens); counter(outputTokens) } }
    class Completed(val reason: ProviderCompletionReason) : ProviderEvent()
    class Cancelled : ProviderEvent()
    class Failed(val code: ProviderFailureCode) : ProviderEvent()
    final override fun toString() = "ProviderEvent(redacted)"
}

/** The wire codec is independent from the legacy store and never writes during migration. */
object NativeConnectionsCodec {
    fun decodeProfile(source: String): ConnectionProfile = profile(ConnectionJSON.parse(source).obj())
    fun encodeProfile(profile: ConnectionProfile): String = ConnectionJSON.write(profileJSON(profile))
    fun decodeEnvelope(source: String, nowEpochMs: Long? = null): ConversationEnvelope {
        val result = envelope(ConnectionJSON.parse(source).obj())
        nowEpochMs?.let { now -> counter(now); result.remoteSession?.pendingApprovals?.forEach { connectionCheck(now < it.expiresAtEpochMs, "approval-expired") } }
        return result
    }
    fun encodeEnvelope(envelope: ConversationEnvelope): String = ConnectionJSON.write(envelopeJSON(envelope))

    /** Any JSON-looking input is versioned data, including malformed/unknown versions; never legacy fallback.
     * Legacy rows that decode documents on a non-user role fail validation, preserving the original source
     * instead of silently dropping documents or granting them a different role. No app storage is switched here.
     */
    fun decodeOrMigrate(source: String, conversationID: String): ConversationEnvelope {
        validateUnicode(source)
        connectionCheck(source.toByteArray(Charsets.UTF_8).size <= NativeConnectionBounds.MAX_ENVELOPE_BYTES, "envelope-limit")
        val first = source.firstOrNull { !it.isWhitespace() }
        if (first == '{' || first == '[') return decodeEnvelope(source)
        val legacy = ConversationStore().decode(source)
        return ConversationEnvelope(conversationID, ConversationBinding.from(ConnectionProfile.localDefault()), legacy.mapIndexed { index, m ->
            ProviderMessage("legacy-$index", if (m.role == Role.USER) ProviderRole.USER else ProviderRole.ASSISTANT, m.text,
                documents = m.documents.map { ProviderDocument(it.name, it.text) })
        })
    }

    private fun profile(o: Map<String, ConnectionJSON.Value>): ConnectionProfile {
        fields(o, "id", "kind", "displayName", "endpoint", "credentialReference", "hostID", "hostFingerprint", "workspaceID")
        return ConnectionProfile.create(o.string("id"), kind(o.string("kind")), o.string("displayName"), o.optionalString("endpoint"),
            o.optionalString("credentialReference"), o.optionalString("hostID"), o.optionalString("hostFingerprint"), o.optionalString("workspaceID"))
    }
    private fun binding(o: Map<String, ConnectionJSON.Value>): ConversationBinding {
        fields(o, "profileID", "kind", "origin", "hostID", "hostFingerprint", "workspaceID")
        return ConversationBinding.create(o.string("profileID"), kind(o.string("kind")), o.optionalString("origin"),
            o.optionalString("hostID"), o.optionalString("hostFingerprint"), o.optionalString("workspaceID"))
    }
    private fun selection(o: Map<String, ConnectionJSON.Value>): ProviderSelection {
        fields(o, "providerID", "modelID", "reasoningEffort")
        return ProviderSelection(o.string("providerID"), o.string("modelID"), enumValue(o.string("reasoningEffort"), ReasoningEffort.entries) { it.wire })
    }
    internal fun message(o: Map<String, ConnectionJSON.Value>): ProviderMessage {
        fields(o, "id", "role", "content", "reasoningContent", "toolCalls", "toolCallID", "documents")
        val calls = o.array("toolCalls", NativeConnectionBounds.MAX_TOOL_CALLS, true).map { value ->
            val call = value.obj(); fields(call, "id", "name", "argumentsJSON")
            ProviderToolCall(call.string("id"), call.string("name"), call.string("argumentsJSON"))
        }
        val documents = o.array("documents", NativeConnectionBounds.MAX_DOCUMENTS, true).map { value ->
            val doc = value.obj(); fields(doc, "name", "text"); ProviderDocument(doc.string("name"), doc.string("text"))
        }
        val role = enumValue(o.string("role"), ProviderRole.entries) { it.wire }
        // Presence of role-inapplicable fields is rejected even if an array is empty.
        connectionCheck(role == ProviderRole.ASSISTANT || (!o.containsKey("reasoningContent") && !o.containsKey("toolCalls")), "invalid-message-role")
        connectionCheck(role == ProviderRole.USER || !o.containsKey("documents"), "invalid-message-role")
        return ProviderMessage(o.string("id"), role, o.string("content"), o.optionalString("reasoningContent"), calls, o.optionalString("toolCallID"), documents)
    }
    private fun remote(o: Map<String, ConnectionJSON.Value>): RemoteSessionState {
        fields(o, "hostID", "deviceID", "workspaceID", "sessionID", "status", "pendingCommands", "pendingApprovals", "runID", "lastConfirmedEventID")
        val commands = o.array("pendingCommands", NativeConnectionBounds.MAX_PENDING).map { value ->
            val c = value.obj(); fields(c, "requestID", "kind", "state")
            PendingRemoteCommand(c.string("requestID"), enumValue(c.string("kind"), RemoteCommandKind.entries) { it.wire }, enumValue(c.string("state"), RemoteCommandState.entries) { it.wire })
        }
        val approvals = o.array("pendingApprovals", NativeConnectionBounds.MAX_PENDING).map { value ->
            val a = value.obj(); fields(a, "approvalID", "requestID", "hostID", "deviceID", "workspaceID", "sessionID", "runID", "actionDigest", "expiresAtEpochMs")
            PendingRemoteApproval(a.string("approvalID"), a.string("requestID"), a.string("hostID"), a.string("deviceID"), a.string("workspaceID"),
                a.string("sessionID"), a.string("runID"), a.string("actionDigest"), a.required("expiresAtEpochMs").integer())
        }
        return RemoteSessionState(o.string("hostID"), o.string("deviceID"), o.string("workspaceID"), o.string("sessionID"),
            enumValue(o.string("status"), RemoteSessionStatus.entries) { it.wire }, commands, approvals, o.optionalString("runID"), o.optionalString("lastConfirmedEventID"))
    }
    private fun envelope(o: Map<String, ConnectionJSON.Value>): ConversationEnvelope {
        fields(o, "schemaVersion", "conversationID", "binding", "messages", "selection", "remoteSession")
        connectionCheck(o.required("schemaVersion").integer() == 1L, "unsupported-version")
        return ConversationEnvelope(o.string("conversationID"), binding(o.required("binding").obj()),
            o.array("messages", NativeConnectionBounds.MAX_MESSAGES).map { message(it.obj()) },
            o["selection"]?.let { selection(it.obj()) }, o["remoteSession"]?.let { remote(it.obj()) })
    }
    private fun kind(value: String) = enumValue(value, ConnectionKind.entries) { it.wire }
    private fun <T> enumValue(value: String, values: List<T>, wire: (T) -> String) = values.singleOrNull { wire(it) == value }
        ?: throw NativeConnectionException("invalid-enum")

    private fun profileJSON(p: ConnectionProfile) = jsonObject("id" to js(p.id), "kind" to js(p.kind.wire), "displayName" to js(p.displayName),
        "endpoint" to p.endpoint?.let(::js), "credentialReference" to p.credentialReference?.let(::js), "hostID" to p.hostID?.let(::js),
        "hostFingerprint" to p.hostFingerprint?.let(::js), "workspaceID" to p.workspaceID?.let(::js))
    private fun bindingJSON(b: ConversationBinding) = jsonObject("profileID" to js(b.profileID), "kind" to js(b.kind.wire), "origin" to b.origin?.let(::js),
        "hostID" to b.hostID?.let(::js), "hostFingerprint" to b.hostFingerprint?.let(::js), "workspaceID" to b.workspaceID?.let(::js))
    internal fun messageJSON(m: ProviderMessage): ConnectionJSON.Value = jsonObject("id" to js(m.id), "role" to js(m.role.wire), "content" to js(m.content),
        "reasoningContent" to m.reasoningContent?.let(::js), "toolCalls" to m.toolCalls.takeIf { it.isNotEmpty() }?.let { ja(it.map { c -> jsonObject("id" to js(c.id), "name" to js(c.name), "argumentsJSON" to js(c.argumentsJSON)) }) },
        "toolCallID" to m.toolCallID?.let(::js), "documents" to m.documents.takeIf { it.isNotEmpty() }?.let { ja(it.map { d -> jsonObject("name" to js(d.name), "text" to js(d.text)) }) })
    private fun remoteJSON(r: RemoteSessionState) = jsonObject("hostID" to js(r.hostID), "deviceID" to js(r.deviceID), "workspaceID" to js(r.workspaceID), "sessionID" to js(r.sessionID),
        "status" to js(r.status.wire), "runID" to r.runID?.let(::js), "lastConfirmedEventID" to r.lastConfirmedEventID?.let(::js),
        "pendingCommands" to ja(r.pendingCommands.map { c -> jsonObject("requestID" to js(c.requestID), "kind" to js(c.kind.wire), "state" to js(c.state.wire)) }),
        "pendingApprovals" to ja(r.pendingApprovals.map { a -> jsonObject("approvalID" to js(a.approvalID), "requestID" to js(a.requestID), "hostID" to js(a.hostID),
            "deviceID" to js(a.deviceID), "workspaceID" to js(a.workspaceID), "sessionID" to js(a.sessionID), "runID" to js(a.runID), "actionDigest" to js(a.actionDigest), "expiresAtEpochMs" to jn(a.expiresAtEpochMs)) }))
    private fun envelopeJSON(e: ConversationEnvelope) = jsonObject("schemaVersion" to jn(1), "conversationID" to js(e.conversationID), "binding" to bindingJSON(e.binding),
        "messages" to ja(e.messages.map(::messageJSON)), "selection" to e.selection?.let { s -> jsonObject("providerID" to js(s.providerID), "modelID" to js(s.modelID), "reasoningEffort" to js(s.reasoningEffort.wire)) },
        "remoteSession" to e.remoteSession?.let(::remoteJSON))
}

internal fun fields(o: Map<String, ConnectionJSON.Value>, vararg allowed: String) = connectionCheck(o.keys.all { it in allowed }, "unknown-field")
internal fun Map<String, ConnectionJSON.Value>.required(key: String) = this[key] ?: throw NativeConnectionException("missing-field")
internal fun Map<String, ConnectionJSON.Value>.string(key: String) = required(key).string()
internal fun Map<String, ConnectionJSON.Value>.optionalString(key: String) = this[key]?.string()
internal fun Map<String, ConnectionJSON.Value>.array(key: String, max: Int, optional: Boolean = false): List<ConnectionJSON.Value> {
    if (optional && !containsKey(key)) return emptyList()
    val array = required(key) as? ConnectionJSON.ArrayValue ?: throw NativeConnectionException("invalid-type")
    connectionCheck(array.values.size <= max, "array-limit"); return array.values
}
private fun js(value: String) = ConnectionJSON.StringValue(value)
private fun jn(value: Long) = ConnectionJSON.NumberValue(value.toString())
private fun ja(values: List<ConnectionJSON.Value>) = ConnectionJSON.ArrayValue(values)
private fun jsonObject(vararg entries: Pair<String, ConnectionJSON.Value?>) = ConnectionJSON.ObjectValue(linkedMapOf<String, ConnectionJSON.Value>().apply {
    entries.forEach { (key, value) -> if (value != null) put(key, value) }
})

/** Small bounded JSON implementation: strict grammar, duplicate keys and invalid Unicode fail closed. */
internal object ConnectionJSON {
    sealed class Value {
        fun obj(): Map<String, Value> = (this as? ObjectValue)?.values ?: throw NativeConnectionException("invalid-type")
        fun string(): String = (this as? StringValue)?.value ?: throw NativeConnectionException("invalid-type")
        fun integer(): Long {
            val token = (this as? NumberValue)?.token ?: throw NativeConnectionException("invalid-type")
            connectionCheck(token.all { it in '0'..'9' } && token.isNotEmpty(), "invalid-counter")
            return (token.toLongOrNull() ?: throw NativeConnectionException("invalid-counter")).also(::counter)
        }
        final override fun toString() = "ConnectionJSON(redacted)"
    }
    class ObjectValue(val values: Map<String, Value>) : Value()
    class ArrayValue(val values: List<Value>) : Value()
    class StringValue(val value: String) : Value()
    class NumberValue(val token: String) : Value()
    class BooleanValue(val value: Boolean) : Value()
    object NullValue : Value()

    fun parse(source: String): Value {
        validateUnicode(source)
        connectionCheck(source.toByteArray(Charsets.UTF_8).size <= NativeConnectionBounds.MAX_ENVELOPE_BYTES, "envelope-limit")
        return Reader(source).read()
    }
    fun write(value: Value): String = buildString { appendJSON(value, 1) }.also {
        connectionCheck(it.toByteArray(Charsets.UTF_8).size <= NativeConnectionBounds.MAX_ENVELOPE_BYTES, "envelope-limit")
    }
    private fun StringBuilder.appendJSON(value: Value, depth: Int) {
        connectionCheck(depth <= NativeConnectionBounds.MAX_JSON_DEPTH, "json-depth")
        when (value) {
            is ObjectValue -> { append('{'); value.values.entries.forEachIndexed { i, entry -> if (i > 0) append(','); appendQuoted(entry.key); append(':'); appendJSON(entry.value, depth + 1) }; append('}') }
            is ArrayValue -> { append('['); value.values.forEachIndexed { i, item -> if (i > 0) append(','); appendJSON(item, depth + 1) }; append(']') }
            is StringValue -> appendQuoted(value.value)
            is NumberValue -> { connectionCheck(Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?").matches(value.token), "invalid-json"); append(value.token) }
            is BooleanValue -> append(if (value.value) "true" else "false")
            NullValue -> append("null")
        }
        connectionCheck(length <= NativeConnectionBounds.MAX_ENVELOPE_BYTES, "envelope-limit")
    }
    private fun StringBuilder.appendQuoted(value: String) {
        text(value); append('"')
        value.forEach { c -> when (c) {
            '"' -> append("\\\""); '\\' -> append("\\\\"); '\b' -> append("\\b"); '\u000c' -> append("\\f"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
            else -> if (c.code < 32) { append("\\u"); append(c.code.toString(16).padStart(4, '0')) } else append(c)
        } }; append('"')
    }

    private class Reader(private val source: String) {
        private var position = 0
        fun read(): Value { val result = value(1); whitespace(); connectionCheck(position == source.length, "invalid-json"); return result }
        private fun whitespace() { while (position < source.length && source[position] in " \t\r\n") position++ }
        private fun take(c: Char): Boolean = if (position < source.length && source[position] == c) { position++; true } else false
        private fun expect(c: Char) = connectionCheck(take(c), "invalid-json")
        private fun value(depth: Int): Value {
            connectionCheck(depth <= NativeConnectionBounds.MAX_JSON_DEPTH, "json-depth"); whitespace()
            connectionCheck(position < source.length, "invalid-json")
            return when (source[position]) {
                '{' -> {
                    position++; whitespace(); val map = linkedMapOf<String, Value>()
                    if (!take('}')) { do {
                        whitespace(); connectionCheck(position < source.length && source[position] == '"', "invalid-json")
                        val key = quoted(); connectionCheck(!map.containsKey(key), "duplicate-key"); whitespace(); expect(':')
                        connectionCheck(map.size < NativeConnectionBounds.MAX_MESSAGES, "object-limit")
                        map[key] = value(depth + 1); whitespace()
                    } while (take(',')); expect('}') }; ObjectValue(map)
                }
                '[' -> {
                    position++; whitespace(); val list = arrayListOf<Value>()
                    if (!take(']')) { do {
                        connectionCheck(list.size < NativeConnectionBounds.MAX_MESSAGES, "array-limit")
                        list.add(value(depth + 1)); whitespace()
                    } while (take(',')); expect(']') }; ArrayValue(list)
                }
                '"' -> StringValue(quoted())
                't' -> { literal("true"); BooleanValue(true) }
                'f' -> { literal("false"); BooleanValue(false) }
                'n' -> { literal("null"); NullValue }
                '-', in '0'..'9' -> number()
                else -> throw NativeConnectionException("invalid-json")
            }
        }
        private fun literal(token: String) {
            connectionCheck(source.regionMatches(position, token, 0, token.length), "invalid-json"); position += token.length
        }
        private fun number(): NumberValue {
            val start = position; take('-')
            connectionCheck(position < source.length, "invalid-json")
            if (!take('0')) { connectionCheck(source[position] in '1'..'9', "invalid-json"); digits() }
            if (take('.')) { val fraction = position; digits(); connectionCheck(position > fraction, "invalid-json") }
            if (take('e') || take('E')) { if (!take('+')) take('-'); val exponent = position; digits(); connectionCheck(position > exponent, "invalid-json") }
            return NumberValue(source.substring(start, position))
        }
        private fun digits() { while (position < source.length && source[position] in '0'..'9') position++ }
        private fun quoted(): String {
            expect('"'); val result = StringBuilder(); var closed = false
            while (position < source.length) {
                val c = source[position++]
                if (c == '"') { closed = true; break }
                connectionCheck(c.code >= 32, "invalid-json")
                if (c != '\\') result.append(c)
                else {
                    connectionCheck(position < source.length, "invalid-json")
                    when (val escape = source[position++]) {
                        '"', '\\', '/' -> result.append(escape)
                        'b' -> result.append('\b'); 'f' -> result.append('\u000c'); 'n' -> result.append('\n'); 'r' -> result.append('\r'); 't' -> result.append('\t')
                        'u' -> {
                            connectionCheck(position + 4 <= source.length, "invalid-json")
                            val token = source.substring(position, position + 4)
                            connectionCheck(token.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }, "invalid-json")
                            result.append(token.toInt(16).toChar()); position += 4
                        }
                        else -> throw NativeConnectionException("invalid-json")
                    }
                }
                connectionCheck(result.length <= NativeConnectionBounds.MAX_TEXT_BYTES, "text-limit")
            }
            connectionCheck(closed, "invalid-json")
            return result.toString().also { text(it) }
        }
    }
}
