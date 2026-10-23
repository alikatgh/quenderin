package ai.quenderin.core

import java.io.File

/** Raw JSON comparison independent of model decoding: preserve every field, array position and scalar. */
private fun canonicalFixtureJSON(value: ConnectionJSON.Value): String {
    fun ordered(value: ConnectionJSON.Value): ConnectionJSON.Value = when (value) {
        is ConnectionJSON.ObjectValue -> ConnectionJSON.ObjectValue(value.values.toSortedMap().mapValues { ordered(it.value) })
        is ConnectionJSON.ArrayValue -> ConnectionJSON.ArrayValue(value.values.map { ordered(it) })
        else -> value
    }
    return ConnectionJSON.write(ordered(value))
}

/** Host JVM verification only. Logs fixture IDs/counts, never provider or transcript payloads. */
fun main(args: Array<String>) {
    if (args.size != 1) throw IllegalArgumentException("Expected one fixture path")
    val file = File(args[0])
    connectionCheck(file.length() <= NativeConnectionBounds.MAX_ENVELOPE_BYTES, "fixture-limit")
    val root = ConnectionJSON.parse(file.readText(Charsets.UTF_8)).obj()
    connectionCheck(root.required("schemaVersion").integer() == 1L, "unsupported-fixtures")
    var fixtures = 0
    var behaviors = 0
    val seen = mutableSetOf<String>()
    fun checkCase(id: String, fixture: Boolean = false, block: () -> Unit) {
        connectionCheck(Regex("^[A-Za-z0-9._-]{1,128}$").matches(id) && seen.add(id), "invalid-case-id")
        try {
            block()
        } catch (_: Throwable) {
            System.err.println("NATIVE_CONNECTION_CASE_FAIL $id")
            throw IllegalStateException("Native connection verification failed: $id")
        }
        if (fixture) { fixtures++; println("NATIVE_CONNECTION_FIXTURE_PASS $id") }
        else { behaviors++; println("NATIVE_CONNECTION_BEHAVIOR_PASS $id") }
    }
    fun expectRejected(block: () -> Unit) {
        var rejected = false
        try { block() } catch (_: NativeConnectionException) { rejected = true }
        check(rejected)
    }
    fun input(o: Map<String, ConnectionJSON.Value>): String = o.optionalString("rawJSON")
        ?: ConnectionJSON.write(o.required("input"))
    val profileCases = root.array("profilesValid", 1_024)
    val envelopeCases = root.array("envelopesValid", 1_024)
    for (value in profileCases) {
        val c = value.obj()
        checkCase(c.string("id"), true) {
            val profile = NativeConnectionsCodec.decodeProfile(input(c))
            val encoded = NativeConnectionsCodec.encodeProfile(profile)
            check(NativeConnectionsCodec.encodeProfile(NativeConnectionsCodec.decodeProfile(encoded)) == encoded)
            val expected = c.required("input").obj().toMutableMap()
            expected["endpoint"]?.let { expected["endpoint"] = ConnectionJSON.StringValue(ConnectionOrigins.canonicalize(it.string())) }
            check(canonicalFixtureJSON(ConnectionJSON.parse(encoded)) == canonicalFixtureJSON(ConnectionJSON.ObjectValue(expected)))
        }
    }
    for (value in root.array("profilesInvalid", 1_024)) {
        val c = value.obj()
        checkCase(c.string("id"), true) { expectRejected { NativeConnectionsCodec.decodeProfile(input(c)) } }
    }
    for (value in envelopeCases) {
        val c = value.obj()
        checkCase(c.string("id"), true) {
            val envelope = NativeConnectionsCodec.decodeEnvelope(input(c))
            val encoded = NativeConnectionsCodec.encodeEnvelope(envelope)
            check(NativeConnectionsCodec.encodeEnvelope(NativeConnectionsCodec.decodeEnvelope(encoded)) == encoded)
            check(canonicalFixtureJSON(ConnectionJSON.parse(encoded)) == canonicalFixtureJSON(c.required("input")))
            val originalMessages = c.required("input").obj().array("messages", 1_024)
            for ((index, valueMessage) in originalMessages.withIndex()) {
                val original = NativeConnectionsCodec.message(valueMessage.obj())
                check(ConnectionJSON.write(NativeConnectionsCodec.messageJSON(original)) == ConnectionJSON.write(NativeConnectionsCodec.messageJSON(envelope.messages[index])))
            }
        }
    }
    for (value in root.array("envelopesInvalid", 1_024)) {
        val c = value.obj()
        checkCase(c.string("id"), true) {
            expectRejected { NativeConnectionsCodec.decodeEnvelope(input(c)) }
            // A corrupt/future versioned value must not be silently imported as an empty legacy conversation.
            expectRejected { NativeConnectionsCodec.decodeOrMigrate(input(c), "must-not-migrate") }
        }
    }
    for (value in root.array("legacy", 1_024)) {
        val c = value.obj()
        checkCase(c.string("id"), true) {
            val source = c.string("kotlinSource")
            val migrated = NativeConnectionsCodec.decodeOrMigrate(source, c.string("conversationID"))
            check(migrated.binding == ConversationBinding.from(ConnectionProfile.localDefault()))
            check(migrated.selection == null && migrated.remoteSession == null)
            val expected = c.array("expectedMessages", 1_024)
            check(migrated.messages.size == expected.size)
            val encoded = NativeConnectionsCodec.encodeEnvelope(migrated)
            val actualMessages = ConnectionJSON.parse(encoded).obj().required("messages")
            check(canonicalFixtureJSON(actualMessages) == canonicalFixtureJSON(ConnectionJSON.ArrayValue(expected)))
            check(NativeConnectionsCodec.encodeEnvelope(NativeConnectionsCodec.decodeEnvelope(encoded)) == encoded)
            check(source == c.string("kotlinSource"))
        }
    }

    val hostFingerprint = "a".repeat(64)
    val actionDigest = "b".repeat(64)
    val remoteProfile = ConnectionProfile.create("remote", ConnectionKind.REMOTE_HARNESS, "Remote", "https://relay.example",
        "qcred:remote", "host-a", hostFingerprint, "workspace-a")
    val binding = ConversationBinding.from(remoteProfile)
    val identity = RemoteIdentity("host-a", "device-a", "workspace-a", "session-a", "run-a")
    fun session(status: RemoteSessionStatus = RemoteSessionStatus.READY,
                commands: List<PendingRemoteCommand> = emptyList(), approvals: List<PendingRemoteApproval> = emptyList()) =
        RemoteSessionState(identity.hostID, identity.deviceID, identity.workspaceID, identity.sessionID, status, commands, approvals, identity.runID)
    fun approval() = PendingRemoteApproval("approval-a", "request-a", identity.hostID, identity.deviceID,
        identity.workspaceID, identity.sessionID, identity.runID!!, actionDigest, 1_000)
    fun awaiting() = session(RemoteSessionStatus.AWAITING_APPROVAL, approvals = listOf(approval()))
    fun decide(state: RemoteSessionState = awaiting(), expected: RemoteIdentity = identity, displayedApproval: PendingRemoteApproval = approval(),
               now: Long = 999, decision: ApprovalDecision = ApprovalDecision.APPROVE) =
        state.consumeApproval(displayedApproval, expected, now, decision, "decision-a")

    checkCase("behavior-origin-canonicalization") {
        check(ConnectionOrigins.canonicalize("HTTPS://RELAY.EXAMPLE:443/") == "https://relay.example")
        check(ConnectionOrigins.canonicalize("https://[2001:DB8::1]:8443/") == "https://[2001:db8::1]:8443")
        for (origin in listOf("https://[not::hex]", "https://[fe80::1%25en0]", "https://relay.example:",
            "https://127.000.0.1", "https://256.1.1.1", "https://-bad.example", "https://relay.example//", "https://relay.example?")) {
            expectRejected { ConnectionOrigins.canonicalize(origin) }
        }
    }
    checkCase("behavior-dispatch-matches-complete-binding") {
        val envelope = ConversationEnvelope("conversation", binding, emptyList())
        envelope.requireDispatch(remoteProfile)
        envelope.requireDispatch(remoteProfile.copy(displayName = "Renamed", credentialReference = "qcred:rotated"))
        for (changed in listOf(remoteProfile.copy(id = "other"), remoteProfile.copy(endpoint = "https://other.example"),
            remoteProfile.copy(hostID = "host-b"), remoteProfile.copy(hostFingerprint = "c".repeat(64)), remoteProfile.copy(workspaceID = "workspace-b"),
            ConnectionProfile.localDefault())) {
            expectRejected { envelope.requireDispatch(changed) }
        }
    }
    checkCase("behavior-approval-identity-digest-expiry") {
        for (wrong in listOf(identity.copy(hostID = "host-b"), identity.copy(deviceID = "device-b"),
            identity.copy(workspaceID = "workspace-b"), identity.copy(sessionID = "session-b"), identity.copy(runID = "run-b"))) {
            expectRejected { decide(expected = wrong) }
        }
        expectRejected { decide(displayedApproval = approval().copy(actionDigest = "c".repeat(64))) }
        expectRejected { decide(displayedApproval = approval().copy(requestID = "request-b")) }
        expectRejected { decide(displayedApproval = approval().copy(expiresAtEpochMs = 2_000)) }
        expectRejected { decide(displayedApproval = approval().copy(hostID = "host-b")) }
        expectRejected { decide(now = 1_000) }
        expectRejected { decide(now = 1_001) }
        expectRejected { decide(now = -1) }
    }
    checkCase("behavior-approval-one-time-and-denial") {
        val consumed = decide()
        check(consumed.pendingApprovals.isEmpty())
        check(consumed.pendingCommands.single().kind == RemoteCommandKind.APPROVE)
        check(consumed.pendingCommands.single().state == RemoteCommandState.PREPARED)
        expectRejected { consumed.consumeApproval(approval(), identity, 999, ApprovalDecision.APPROVE, "decision-b") }
        check(decide(decision = ApprovalDecision.DENY).pendingCommands.single().kind == RemoteCommandKind.DENY)
        expectRejected { session().prepare("bypass", RemoteCommandKind.APPROVE) }
        expectRejected { session().prepare("bypass", RemoteCommandKind.DENY) }
    }
    checkCase("behavior-command-send-ack-matching") {
        val prepared = session().prepare("send-a", RemoteCommandKind.SEND)
        expectRejected { prepared.acknowledge("send-a", identity, "event:wrong-before-send") }
        val sent = prepared.markSent("send-a", identity)
        check(sent.status == RemoteSessionStatus.RUNNING)
        expectRejected { sent.markSent("send-a", identity) }
        expectRejected { sent.acknowledge("send-a", identity.copy(deviceID = "device-b"), "event:1") }
        expectRejected { sent.acknowledge("other", identity, "event:1") }
        val confirmed = sent.acknowledge("send-a", identity, "opaque:42/position")
        check(confirmed.pendingCommands.single().state == RemoteCommandState.ACKNOWLEDGED)
        check(confirmed.lastConfirmedEventID == "opaque:42/position")
        check(confirmed.disconnected().status == RemoteSessionStatus.OUTCOME_UNKNOWN)
        expectRejected { confirmed.acknowledge("send-a", identity, "event:2") }
        val awaitingState = session(RemoteSessionStatus.AWAITING_APPROVAL, approvals = listOf(approval(),
            approval().copy(approvalID = "approval-b", requestID = "request-b")))
        check(decide(state = awaitingState).markSent("decision-a", identity).status == RemoteSessionStatus.AWAITING_APPROVAL)
        check(decide().markSent("decision-a", identity).status == RemoteSessionStatus.RUNNING)
    }
    checkCase("behavior-disconnect-does-not-replay") {
        val initial = session().prepare("unsent", RemoteCommandKind.SEND).prepare("sent", RemoteCommandKind.SEND).markSent("sent", identity)
        val lost = initial.disconnected()
        check(lost.status == RemoteSessionStatus.OUTCOME_UNKNOWN)
        check(lost.pendingCommands[0].state == RemoteCommandState.PREPARED)
        check(lost.pendingCommands[1].state == RemoteCommandState.OUTCOME_UNKNOWN)
        expectRejected { lost.markSent("sent", identity) }
        expectRejected { lost.markSent("unsent", identity) }
        expectRejected { lost.prepare("new", RemoteCommandKind.SEND) }
        val reconciled = lost.acknowledge("sent", identity, "event:confirmed")
        check(reconciled.pendingCommands[1].state == RemoteCommandState.ACKNOWLEDGED)
        check(session().disconnected().status == RemoteSessionStatus.DISCONNECTED)
        check(session(RemoteSessionStatus.RUNNING).disconnected().status == RemoteSessionStatus.OUTCOME_UNKNOWN)
    }
    checkCase("behavior-stop-requires-confirmation") {
        val stoppedRequest = session(RemoteSessionStatus.RUNNING).prepare("earlier-send", RemoteCommandKind.SEND).prepare("stop-a", RemoteCommandKind.STOP)
        check(stoppedRequest.status == RemoteSessionStatus.STOP_REQUESTED)
        expectRejected { stoppedRequest.markSent("earlier-send", identity) }
        expectRejected { stoppedRequest.prepare("later-send", RemoteCommandKind.SEND) }
        val sent = stoppedRequest.markSent("stop-a", identity)
        check(sent.status == RemoteSessionStatus.STOP_REQUESTED)
        val lost = sent.disconnected()
        check(lost.status == RemoteSessionStatus.OUTCOME_UNKNOWN)
        check(lost.acknowledge("stop-a", identity, "event:stopped").status == RemoteSessionStatus.STOPPED)
        val confirmedStopped = sent.acknowledge("stop-a", identity, "event:stopped")
        check(confirmedStopped.status == RemoteSessionStatus.STOPPED)
        check(confirmedStopped.disconnected().status == RemoteSessionStatus.STOPPED)
    }
    checkCase("behavior-recovery-roundtrip-preserves-state") {
        val lost = decide().markSent("decision-a", identity).disconnected()
        val original = ConversationEnvelope("state", binding, emptyList(), remoteSession = lost)
        val encoded = NativeConnectionsCodec.encodeEnvelope(original)
        val restored = NativeConnectionsCodec.decodeEnvelope(encoded)
        check(NativeConnectionsCodec.encodeEnvelope(restored) == encoded)
        check(restored.remoteSession!!.pendingApprovals.isEmpty())
        check(restored.remoteSession.pendingCommands.single().state == RemoteCommandState.OUTCOME_UNKNOWN)
        expectRejected { restored.remoteSession.consumeApproval(approval(), identity, 999, ApprovalDecision.APPROVE, "another") }
    }
    checkCase("behavior-caller-supplied-expiry-check") {
        val encoded = NativeConnectionsCodec.encodeEnvelope(ConversationEnvelope("expiry", binding, emptyList(), remoteSession = awaiting()))
        NativeConnectionsCodec.decodeEnvelope(encoded, 999)
        expectRejected { NativeConnectionsCodec.decodeEnvelope(encoded, 1_000) }
    }
    checkCase("behavior-unsupported-legacy-keeps-source") {
        val source = "ASSISTANT\tanswer\tnote.txt\tdocument"
        check(ConversationStore().decode(source).single().documents.single().text == "document")
        expectRejected { NativeConnectionsCodec.decodeOrMigrate(source, "legacy-invalid-role") }
        check(source == "ASSISTANT\tanswer\tnote.txt\tdocument")
    }
    checkCase("behavior-content-roundtrip-and-no-diagnostics") {
        val secretSentinel = "sensitive-provider-content-雪-🚀"
        val messages = listOf(ProviderMessage("assistant", ProviderRole.ASSISTANT, secretSentinel, "$secretSentinel\r\n\t\\",
            listOf(ProviderToolCall("call", "tool", "{ \"lossless\": 1.00 }\n"))),
            ProviderMessage("tool", ProviderRole.TOOL, secretSentinel, toolCallID = "call"))
        val envelope = ConversationEnvelope("preserve", binding, messages, ProviderSelection("provider", "model", ReasoningEffort.HIGH))
        val encoded = NativeConnectionsCodec.encodeEnvelope(envelope)
        val restored = NativeConnectionsCodec.decodeEnvelope(encoded)
        check(restored.messages[0].reasoningContent == messages[0].reasoningContent)
        check(restored.messages[0].toolCalls[0].argumentsJSON == messages[0].toolCalls[0].argumentsJSON)
        check(restored.messages[1].content == secretSentinel)
        val request = ProviderRequest("request", envelope, remoteProfile, ProviderCapabilities(true, true, true, true, true), emptyList(), ProviderRequestLimits(20, 1, 1_000), 999)
        val diagnostics = listOf(envelope, messages[0], messages[0].toolCalls[0], request, ProviderEvent.Text("m", secretSentinel),
            ProviderEvent.Reasoning("m", secretSentinel), ProviderDocument(secretSentinel, secretSentinel),
            ProviderEvent.ToolCallFragment("m", "call", 0, "tool", secretSentinel))
        check(diagnostics.none { secretSentinel in it.toString() })
        try { NativeConnectionsCodec.decodeProfile("{\"$secretSentinel\":1}") } catch (error: NativeConnectionException) {
            check(secretSentinel !in error.toString())
        }
    }
    checkCase("behavior-input-snapshots-are-defensive") {
        val tools = mutableListOf(ProviderToolCall("call", "tool", "{}"))
        val messages = mutableListOf(ProviderMessage("m", ProviderRole.ASSISTANT, "", toolCalls = tools))
        val envelope = ConversationEnvelope("snapshot", binding, messages)
        tools.clear(); messages.clear()
        check(envelope.messages.size == 1 && envelope.messages.single().toolCalls.size == 1)
        val commands = mutableListOf(PendingRemoteCommand("prepared", RemoteCommandKind.SEND, RemoteCommandState.PREPARED))
        val remote = session(commands = commands)
        commands.clear(); check(remote.pendingCommands.size == 1)
        var immutable = false
        try { (envelope.messages as MutableList<ProviderMessage>).clear() } catch (_: UnsupportedOperationException) { immutable = true }
        check(immutable)
    }
    checkCase("behavior-provider-capabilities-limits") {
        val selection = ProviderSelection("provider", "model", ReasoningEffort.OFF)
        val capabilities = ProviderCapabilities(true, true, true, true, true)
        val limits = ProviderRequestLimits(10, 1, 1_000)
        val documentEnvelope = ConversationEnvelope("request", binding,
            listOf(ProviderMessage("m", ProviderRole.USER, "", documents = listOf(ProviderDocument("note", "text")))), selection)
        expectRejected { ProviderRequest("request", documentEnvelope, remoteProfile, capabilities.copy(documents = false), emptyList(), limits, 999) }
        expectRejected { ProviderRequest("request", documentEnvelope, remoteProfile.copy(hostID = "wrong"), capabilities, emptyList(), limits, 999) }
        val request = ProviderRequest("request", documentEnvelope, remoteProfile, capabilities, emptyList(), limits, 999)
        check(request.selection === selection && request.conversationID == "request")
        check(request.capabilities.cancellation && request.capabilities.usage)
        expectRejected { ProviderRequest("request", ConversationEnvelope("request", binding, emptyList()), remoteProfile, capabilities, emptyList(), limits, 999) }
        for (now in listOf(-1L, 1_000L, 1_001L, NativeConnectionBounds.MAX_COUNTER + 1)) {
            expectRejected { ProviderRequest("request", documentEnvelope, remoteProfile, capabilities, emptyList(), limits, now) }
        }
        val reasoningHistory = ConversationEnvelope("reasoning", binding,
            listOf(ProviderMessage("m", ProviderRole.ASSISTANT, "answer", reasoningContent = "historical reasoning")), selection)
        expectRejected { ProviderRequest("request", reasoningHistory, remoteProfile, capabilities.copy(reasoning = false), emptyList(), limits, 999) }
        val reasoningSelection = ConversationEnvelope("reasoning", binding, emptyList(), selection.copy(reasoningEffort = ReasoningEffort.HIGH))
        expectRejected { ProviderRequest("request", reasoningSelection, remoteProfile, capabilities.copy(reasoning = false), emptyList(), limits, 999) }
        val toolHistory = ConversationEnvelope("tool-history", binding,
            listOf(ProviderMessage("m", ProviderRole.ASSISTANT, "", toolCalls = listOf(ProviderToolCall("call", "tool", "{}")))), selection)
        expectRejected { ProviderRequest("request", toolHistory, remoteProfile, capabilities.copy(toolCalls = false), emptyList(), limits, 999) }
        val toolResults = ConversationEnvelope("tool-results", binding,
            listOf(ProviderMessage("m", ProviderRole.TOOL, "result", toolCallID = "call")), selection)
        expectRejected { ProviderRequest("request", toolResults, remoteProfile, capabilities.copy(toolCalls = false), emptyList(), limits, 999) }
        expectRejected { ProviderRequest("request", documentEnvelope, remoteProfile, capabilities.copy(toolCalls = false),
            listOf(ProviderToolDefinition("tool", "description", "{}")), limits, 999) }
        expectRejected { ProviderRequestLimits(0, 1, 1_000) }
        expectRejected { ProviderRequestLimits(10, 129, 1_000) }
        expectRejected { ProviderRequestLimits(10, 1, 0) }
        expectRejected { ProviderToolDefinition("tool", "description", "{broken}") }
        expectRejected { ProviderEvent.Usage(-1, 0) }
    }
    checkCase("behavior-validated-provider-event-boundary") {
        val text = ProviderEvent.Text("message", "delta")
        val reasoning = ProviderEvent.Reasoning("message", "reasoning")
        val fragment = ProviderEvent.ToolCallFragment("message", null, 127, null, "{\"part\":")
        check(text.messageID == "message" && reasoning.messageID == "message")
        check(fragment.callID == null && fragment.name == null && fragment.argumentsDelta == "{\"part\":")
        expectRejected { ProviderEvent.Text("", "delta") }
        expectRejected { ProviderEvent.Reasoning("../message", "delta") }
        expectRejected { ProviderEvent.ToolCallFragment("message", "", 0, null, "") }
        expectRejected { ProviderEvent.ToolCallFragment("message", null, 0, "bad/name", "") }
        for (index in listOf(-1, 128)) expectRejected { ProviderEvent.ToolCallFragment("message", null, index, null, "") }
        expectRejected { ProviderEvent.Text("message", "x".repeat(NativeConnectionBounds.MAX_TEXT_BYTES + 1)) }
        expectRejected { ProviderEvent.Reasoning("message", "x".repeat(NativeConnectionBounds.MAX_TEXT_BYTES + 1)) }
        expectRejected { ProviderEvent.ToolCallFragment("message", null, 0, null, "x".repeat(NativeConnectionBounds.MAX_TEXT_BYTES + 1)) }
        expectRejected { ProviderEvent.Usage(0, NativeConnectionBounds.MAX_COUNTER + 1) }
        ProviderEvent.Usage(NativeConnectionBounds.MAX_COUNTER, 0)
        check(ProviderCompletionReason.entries.map { ProviderEvent.Completed(it).reason.wire } == listOf("end", "toolCalls", "outputLimit"))
        check(ProviderFailureCode.entries.map { ProviderEvent.Failed(it).code.wire }.toSet() ==
            setOf("unavailable", "unauthorized", "rateLimited", "deadlineExceeded", "invalidResponse", "connectionLost", "rejected", "limitExceeded", "outcomeUnknown"))
        check(ProviderEvent.Cancelled().toString() == "ProviderEvent(redacted)")
    }
    checkCase("behavior-strict-json-numbers-unicode-depth") {
        for (value in listOf("01", "-01", "+1", "1.", "1e", "1e+", "NaN", "true false", "[1,]", "{\"a\":1,}", "\"\\uD800\"", "\"\\uDC00\"")) {
            expectRejected { ConnectionJSON.parse(value) }
        }
        for (number in listOf("0", "-0", "-1.25e+3", "1E-2")) ConnectionJSON.parse(number)
        val deep = "[".repeat(33) + "0" + "]".repeat(33)
        expectRejected { ConnectionJSON.parse(deep) }
        check(ConnectionJSON.parse("\"\\uD83D\\uDE80\"").string() == "🚀")
        expectRejected { ConnectionJSON.parse("\"" + '\uD800' + "\"") }
    }
    checkCase("behavior-size-and-array-bounds") {
        expectRejected { ProviderMessage("big", ProviderRole.USER, "x".repeat(NativeConnectionBounds.MAX_TEXT_BYTES + 1)) }
        expectRejected { ProviderMessage("big", ProviderRole.USER, "雪".repeat(NativeConnectionBounds.MAX_TEXT_BYTES / 3 + 1)) }
        expectRejected { ConversationEnvelope("too-many", binding, (0..1_024).map { ProviderMessage("m-$it", ProviderRole.USER, "") }) }
        expectRejected { RemoteSessionState("host-a", "device-a", "workspace-a", "session-a", RemoteSessionStatus.READY,
            (0..128).map { PendingRemoteCommand("request-$it", RemoteCommandKind.SEND, RemoteCommandState.PREPARED) }) }
        expectRejected { NativeConnectionsCodec.decodeEnvelope(" ".repeat(NativeConnectionBounds.MAX_ENVELOPE_BYTES + 1)) }
        val megabyte = "x".repeat(NativeConnectionBounds.MAX_TEXT_BYTES)
        expectRejected { ConversationEnvelope("aggregate", binding, (0..8).map { ProviderMessage("m-$it", ProviderRole.USER, megabyte) }) }
        expectRejected { ConversationEnvelope("aggregate-reasoning", binding,
            (0..8).map { ProviderMessage("m-$it", ProviderRole.ASSISTANT, "", reasoningContent = megabyte) }) }
        expectRejected { ConversationEnvelope("aggregate-documents", binding, listOf(ProviderMessage("m", ProviderRole.USER, "",
            documents = (0..8).map { ProviderDocument("d-$it", megabyte) }))) }
        expectRejected { ConversationEnvelope("aggregate-tool-arguments", binding, listOf(ProviderMessage("m", ProviderRole.ASSISTANT, "",
            toolCalls = (0..8).map { ProviderToolCall("call-$it", "tool", megabyte) }))) }
        val unicodeMegabyte = "雪".repeat(NativeConnectionBounds.MAX_TEXT_BYTES / 3)
        expectRejected { ConversationEnvelope("aggregate-utf8", binding, (0..7).map { ProviderMessage("m-$it", ProviderRole.USER, unicodeMegabyte) }) }
        val escapedContent = "\u0001".repeat(NativeConnectionBounds.MAX_TEXT_BYTES)
        val wireOversized = ConversationEnvelope("aggregate-wire", binding, (0..1).map { ProviderMessage("m-$it", ProviderRole.USER, escapedContent) })
        expectRejected { NativeConnectionsCodec.encodeEnvelope(wireOversized) }
        val requestEnvelope = ConversationEnvelope("aggregate-request", binding, emptyList(), ProviderSelection("provider", "model", ReasoningEffort.OFF))
        val capabilities = ProviderCapabilities(true, true, true, true, true)
        val limits = ProviderRequestLimits(10, 128, 1_000)
        expectRejected { ProviderRequest("request", requestEnvelope, remoteProfile, capabilities,
            (0..8).map { ProviderToolDefinition("tool-$it", megabyte, "{}") }, limits, 999) }
        val largeSchema = "{\"payload\":\"" + "x".repeat(NativeConnectionBounds.MAX_TEXT_BYTES - 14) + "\"}"
        expectRejected { ProviderRequest("request", requestEnvelope, remoteProfile, capabilities,
            (0..8).map { ProviderToolDefinition("tool-$it", "", largeSchema) }, limits, 999) }
    }
    println("NATIVE_CONNECTION_COUNTS fixtures=$fixtures behaviors=$behaviors")
}
