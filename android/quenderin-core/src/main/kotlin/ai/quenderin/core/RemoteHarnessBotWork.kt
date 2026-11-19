package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.security.MessageDigest

/** Ephemeral submission; only its digest and scoped receipt enter the command journal. */
class RemoteHarnessBotSubmission internal constructor(
    val workspaceID: String, val botID: String, val sessionID: String, val revision: Long,
    val commandID: String, val text: String, val params: RemoteHarnessJSON.ObjectValue,
) {
    val digest: String = MessageDigest.getInstance("SHA-256").digest(RemoteHarnessJSON.write(params).toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    override fun toString() = "RemoteHarnessBotSubmission(redacted)"
}

enum class RemoteHarnessBotCommandState(val wire: String) { PENDING("pending"), ACCEPTED("accepted"), REJECTED("rejected"), UNCERTAIN("uncertain"), NOT_FOUND("notFound") }

data class RemoteHarnessBotCommandReceipt internal constructor(
    val workspaceID: String, val botID: String, val commandID: String, val sessionID: String?, val revision: Long?,
    val state: RemoteHarnessBotCommandState, val reason: String?,
) { override fun toString() = "RemoteHarnessBotCommandReceipt(redacted)" }

/** Fixed, bounded Bot work extension. No generic plugin calls or raw-session prompting. */
object RemoteHarnessBotWork {
    const val CAPABILITY = "quenderin.bot.work.v1"
    const val SUBMIT = "quenderin-submit"
    const val COMMAND = "quenderin-command"
    const val TEXT_BYTES = 16_384
    const val REQUEST_BYTES = 32_768
    const val RESULT_BYTES = 8_192
    const val COMMAND_ID_BYTES = 128
    const val MAX_REVISION = 9_007_199_254_740_991L
    val reasons = setOf("staleSession", "staleRevision", "unavailable", "readOnly", "revoked", "wrongScope", "payloadConflict",
        "capacity", "storageFailure", "dispatchUncertain", "invalidRequest")

    internal fun identity(value: String, limit: Int = RemoteHarnessBotRead.IDENTITY_BYTES): String {
        rhUnicode(value)
        rhCheck(value.isNotEmpty() && '\u0000' !in value && value.toByteArray(Charsets.UTF_8).size <= limit, "invalid-bot-work-string")
        return value
    }
    internal fun revision(value: Long): Long { rhCheck(value in 0..MAX_REVISION, "invalid-bot-work-revision"); return value }
    fun submission(workspaceID: String, botID: String, sessionID: String, revision: Long, commandID: String, text: String): RemoteHarnessBotSubmission {
        identity(workspaceID); identity(botID); identity(sessionID); identity(commandID, COMMAND_ID_BYTES); this.revision(revision)
        identity(text, TEXT_BYTES); rhCheck(text.isNotBlank(), "invalid-bot-work-text")
        val params = route(SUBMIT, obj("schemaVersion" to num(1), "workspaceId" to str(workspaceID), "botId" to str(botID),
            "expectedSessionId" to str(sessionID), "expectedRevision" to num(revision), "commandId" to str(commandID), "text" to str(text)))
        return RemoteHarnessBotSubmission(workspaceID, botID, sessionID, revision, commandID, text, params)
    }
    fun command(workspaceID: String, botID: String, commandID: String): RemoteHarnessJSON.ObjectValue {
        identity(workspaceID); identity(botID); identity(commandID, COMMAND_ID_BYTES)
        return route(COMMAND, obj("schemaVersion" to num(1), "workspaceId" to str(workspaceID), "botId" to str(botID), "commandId" to str(commandID)))
    }
    fun validateRequest(value: RemoteHarnessJSON, expectedWorkspaceID: String? = null) {
        limit(value, REQUEST_BYTES)
        val p = value.objectValue(); exact(p, "route", "body")
        rhCheck(p.rhString("route") == RemoteHarnessBotRead.ROUTE, "unsupported-bot-route")
        val body = p.rhRequired("body").objectValue(); exact(body, "endpoint", "payload")
        val payload = body.rhRequired("payload").objectValue()
        when (body.rhString("endpoint")) {
            SUBMIT -> {
                exact(payload, "schemaVersion", "workspaceId", "botId", "expectedSessionId", "expectedRevision", "commandId", "text")
                submission(payload.rhString("workspaceId"), payload.rhString("botId"), payload.rhString("expectedSessionId"),
                    payload.rhRequired("expectedRevision").integerValue(), payload.rhString("commandId"), payload.rhString("text"))
            }
            COMMAND -> {
                exact(payload, "schemaVersion", "workspaceId", "botId", "commandId")
                command(payload.rhString("workspaceId"), payload.rhString("botId"), payload.rhString("commandId"))
            }
            else -> throw RemoteHarnessException("unsupported-bot-endpoint")
        }
        rhCheck(payload.rhRequired("schemaVersion").integerValue() == 1L, "unsupported-bot-work-version")
        expectedWorkspaceID?.let { rhCheck(payload.rhString("workspaceId") == identity(it), "workspace-binding-mismatch") }
    }
    fun receipt(value: RemoteHarnessJSON, submission: RemoteHarnessBotSubmission): RemoteHarnessBotCommandReceipt =
        receipt(value, submission.workspaceID, submission.botID, submission.commandID).also { receipt ->
            rhCheck(receipt.state !in setOf(RemoteHarnessBotCommandState.ACCEPTED, RemoteHarnessBotCommandState.UNCERTAIN) ||
                receipt.sessionID == submission.sessionID && receipt.revision == submission.revision, "bot-work-binding-mismatch")
        }
    private fun route(endpoint: String, payload: RemoteHarnessJSON) = obj("route" to str(RemoteHarnessBotRead.ROUTE),
        "body" to obj("endpoint" to str(endpoint), "payload" to payload)).also { limit(it, REQUEST_BYTES) }
    internal fun supported(describe: RemoteHarnessJSON): Boolean = RemoteHarnessBotRead.supported(describe) &&
        (describe.objectValue().rhRequired("capabilities") as RemoteHarnessJSON.ArrayValue).values.any { it.stringValue() == CAPABILITY }
    fun receipt(value: RemoteHarnessJSON, workspaceID: String, botID: String, commandID: String): RemoteHarnessBotCommandReceipt {
        limit(value, RESULT_BYTES)
        val response = value.objectValue(); exact(response, "status", "json")
        rhCheck(response.rhRequired("status").integerValue() == 200L, "bot-work-unavailable")
        val json = response.rhRequired("json").objectValue(); exact(json, "ok", "value")
        rhCheck(json.rhRequired("ok").booleanValue(), "bot-work-unavailable")
        val p = json.rhRequired("value").objectValue(); exact(p, "schemaVersion", "workspaceId", "botId", "commandId", "sessionId", "revision", "state", "reason")
        rhCheck(p.rhRequired("schemaVersion").integerValue() == 1L, "unsupported-bot-work-version")
        rhCheck(identity(p.rhString("workspaceId")) == workspaceID && identity(p.rhString("botId")) == botID &&
            identity(p.rhString("commandId"), COMMAND_ID_BYTES) == commandID, "bot-work-binding-mismatch")
        val session = p.rhRequired("sessionId").let { if (it === RemoteHarnessJSON.NullValue) null else identity(it.stringValue()) }
        val rev = p.rhRequired("revision").let { if (it === RemoteHarnessJSON.NullValue) null else revision(it.integerValue()) }
        val state = RemoteHarnessBotCommandState.entries.singleOrNull { it != RemoteHarnessBotCommandState.PENDING && it.wire == p.rhString("state") }
            ?: throw RemoteHarnessException("invalid-bot-work-state")
        val reason = p.rhRequired("reason").let { if (it === RemoteHarnessJSON.NullValue) null else it.stringValue().also { name -> rhCheck(name in reasons, "invalid-bot-work-reason") } }
        rhCheck((session == null) == (rev == null), "invalid-bot-work-part")
        rhCheck(state != RemoteHarnessBotCommandState.ACCEPTED || session != null && reason == null, "invalid-bot-work-receipt")
        rhCheck(state != RemoteHarnessBotCommandState.NOT_FOUND || session == null && reason == null, "invalid-bot-work-receipt")
        rhCheck(state != RemoteHarnessBotCommandState.REJECTED || session == null && reason != null, "invalid-bot-work-receipt")
        rhCheck(state != RemoteHarnessBotCommandState.UNCERTAIN || session != null && reason == "dispatchUncertain", "invalid-bot-work-receipt")
        return RemoteHarnessBotCommandReceipt(workspaceID, botID, commandID, session, rev, state, reason)
    }
    private fun exact(p: Map<String, RemoteHarnessJSON>, vararg names: String) = rhCheck(p.keys == names.toSet(), "invalid-bot-work-fields")
    private fun limit(value: RemoteHarnessJSON, bytes: Int) {
        (value as? RemoteHarnessJSON.ObjectValue)?.sourceUTF8Bytes?.let { rhCheck(it <= bytes, "bot-work-limit") }
        rhCheck(RemoteHarnessJSON.write(value).toByteArray(Charsets.UTF_8).size <= bytes, "bot-work-limit")
    }
}
