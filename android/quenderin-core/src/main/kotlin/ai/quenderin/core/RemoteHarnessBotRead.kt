package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.util.Collections

/** Display metadata only. Ownership/provenance must come from an installed authoritative Host adapter. */
class RemoteHarnessBotSummary internal constructor(
    val id: String, val name: String, val sessionID: String, val model: String?, val permission: String?,
) {
    override fun toString() = "RemoteHarnessBotSummary(redacted)"
}

/** Validated read-only snapshot; contains no connection identity, authorization or actionable commands. */
class RemoteHarnessBotRoster internal constructor(
    val workspaceID: String, val revision: Long, val readOnly: Boolean, bots: List<RemoteHarnessBotSummary>,
) {
    val schemaVersion = 1
    val bots: List<RemoteHarnessBotSummary> = Collections.unmodifiableList(ArrayList(bots))
    override fun toString() = "RemoteHarnessBotRoster(redacted)"
}

/** Quenderin extension only. The current Host companion neither installs nor advertises this route.
 * This codec performs no I/O, bootstrap, generic plugin dispatch, mutation or session authorization. */
object RemoteHarnessBotRead {
    const val CAPABILITY = "quenderin.bot.read.v1"
    const val CARRIER_CAPABILITY = "plugin.route.v1"
    const val METHOD = "plugin.route.call"
    const val ROUTE = "api/bot"
    const val ENDPOINT = "quenderin-roster"
    const val REQUEST_BYTES = 4_096
    const val RESULT_BYTES = 262_144
    const val MAX_BOTS = 100
    const val IDENTITY_BYTES = 1_024
    const val NAME_BYTES = 256
    const val MODEL_BYTES = 256
    const val PERMISSION_BYTES = 64

    fun request(workspaceID: String): RemoteHarnessJSON.ObjectValue {
        boundedString(workspaceID, IDENTITY_BYTES)
        return obj("route" to str(ROUTE), "body" to obj("endpoint" to str(ENDPOINT), "payload" to obj(
            "schemaVersion" to num(1), "workspaceId" to str(workspaceID)))).also { validateRequest(it, workspaceID) }
    }

    /** Exact fixed request policy. An expected workspace is mandatory at the coordinator boundary. */
    fun validateRequest(value: RemoteHarnessJSON, expectedWorkspaceID: String? = null) {
        encodedLimit(value, REQUEST_BYTES, "bot-request-limit")
        val params = value.objectValue(); exact(params, "route", "body")
        rhCheck(params.rhString("route") == ROUTE, "unsupported-bot-route")
        val body = params.rhRequired("body").objectValue(); exact(body, "endpoint", "payload")
        rhCheck(body.rhString("endpoint") == ENDPOINT, "unsupported-bot-endpoint")
        val payload = body.rhRequired("payload").objectValue(); exact(payload, "schemaVersion", "workspaceId")
        rhCheck(payload.rhRequired("schemaVersion").integerValue() == 1L, "unsupported-bot-version")
        val workspaceID = boundedString(payload.rhString("workspaceId"), IDENTITY_BYTES)
        expectedWorkspaceID?.let {
            boundedString(it, IDENTITY_BYTES)
            rhCheck(workspaceID == it, "workspace-binding-mismatch")
        }
    }

    /** Both capabilities are required; the authenticated coordinator owns their connection lifetime. */
    internal fun supported(describe: RemoteHarnessJSON): Boolean {
        val capabilities = describe.objectValue().rhRequired("capabilities") as? RemoteHarnessJSON.ArrayValue
            ?: throw RemoteHarnessException("invalid-capabilities")
        val names = capabilities.values.map { it.stringValue() }
        return CAPABILITY in names && CARRIER_CAPABILITY in names
    }

    /** Raw plugin route response, deliberately separate from harness.remote.call's Gateway envelope. */
    fun result(bytes: ByteArray, expectedWorkspaceID: String): RemoteHarnessBotRoster {
        rhCheck(bytes.size <= RESULT_BYTES, "bot-result-limit")
        return result(RemoteHarnessJSON.parse(bytes), expectedWorkspaceID)
    }

    fun result(value: RemoteHarnessJSON, expectedWorkspaceID: String): RemoteHarnessBotRoster {
        boundedString(expectedWorkspaceID, IDENTITY_BYTES)
        encodedLimit(value, RESULT_BYTES)
        val result = value.objectValue(); exact(result, "status", "json")
        rhCheck(result.rhRequired("status").integerValue() == 200L, "bot-read-unavailable")
        val json = result.rhRequired("json").objectValue(); exact(json, "ok", "value")
        rhCheck(json.rhRequired("ok").booleanValue(), "bot-read-unavailable")
        val snapshot = json.rhRequired("value").objectValue()
        exact(snapshot, "schemaVersion", "workspaceId", "revision", "readOnly", "bots")
        rhCheck(snapshot.rhRequired("schemaVersion").integerValue() == 1L, "unsupported-bot-version")
        val workspaceID = boundedString(snapshot.rhString("workspaceId"), IDENTITY_BYTES)
        // Valid Unicode scalar strings have an injective UTF-8 encoding: equality never normalizes.
        rhCheck(workspaceID == expectedWorkspaceID, "workspace-binding-mismatch")
        val revision = snapshot.rhRequired("revision").integerValue()
        val readOnly = snapshot.rhRequired("readOnly").booleanValue()
        val list = snapshot.rhRequired("bots") as? RemoteHarnessJSON.ArrayValue ?: throw RemoteHarnessException("invalid-type")
        rhCheck(list.values.size <= MAX_BOTS, "bot-count-limit")
        val ids = hashSetOf<String>(); val sessions = hashSetOf<String>()
        val bots = list.values.map { item ->
            val bot = item.objectValue(); exact(bot, "id", "name", "sessionId", "model", "permission")
            val id = boundedString(bot.rhString("id"), IDENTITY_BYTES)
            val sessionID = boundedString(bot.rhString("sessionId"), IDENTITY_BYTES)
            rhCheck(ids.add(id) && sessions.add(sessionID), "duplicate-bot-identity")
            RemoteHarnessBotSummary(id, boundedString(bot.rhString("name"), NAME_BYTES), sessionID,
                nullableString(bot.rhRequired("model"), MODEL_BYTES), nullableString(bot.rhRequired("permission"), PERMISSION_BYTES))
        }
        return RemoteHarnessBotRoster(workspaceID, revision, readOnly, bots)
    }

    private fun exact(value: Map<String, RemoteHarnessJSON>, vararg fields: String) =
        rhCheck(value.keys == fields.toSet(), "invalid-bot-fields")
    private fun boundedString(value: String, limit: Int): String {
        rhUnicode(value)
        rhCheck(value.isNotEmpty() && '\u0000' !in value && value.toByteArray(Charsets.UTF_8).size <= limit, "invalid-bot-string")
        return value
    }
    private fun nullableString(value: RemoteHarnessJSON, limit: Int): String? =
        if (value === RemoteHarnessJSON.NullValue) null else boundedString(value.stringValue(), limit)
    private fun encodedLimit(value: RemoteHarnessJSON, limit: Int, code: String = "bot-result-limit") {
        // Parsed route results retain their exact original object byte count. Re-encoding alone
        // would erase whitespace/escape expansion and admit an over-limit carrier result.
        (value as? RemoteHarnessJSON.ObjectValue)?.sourceUTF8Bytes?.let { rhCheck(it <= limit, code) }
        rhCheck(RemoteHarnessJSON.write(value).toByteArray(Charsets.UTF_8).size <= limit, code)
    }
}
