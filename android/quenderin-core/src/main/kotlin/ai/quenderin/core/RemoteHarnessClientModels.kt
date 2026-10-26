package ai.quenderin.core

import java.security.MessageDigest
import java.util.Base64

/** Enrollment and transcript records deliberately have different stores and never share keys. */
enum class RemoteHarnessCredentialPhase { RESERVED, READY, REFRESH_PENDING, REAUTHORIZE }

class RemoteHarnessClientCredentials(
    val origin: String, val deviceID: String, privateSeed: ByteArray,
    val phase: RemoteHarnessCredentialPhase = RemoteHarnessCredentialPhase.RESERVED,
    val accessToken: String? = null, val accessExpiresAt: Long = 0,
    val refreshToken: String? = null, val refreshExpiresAt: Long = 0,
) {
    private val seed = privateSeed.copyOf()
    init {
        rhCheck(origin == ConnectionOrigins.canonicalize(origin), "client-origin")
        rhID(deviceID); rhCheck(seed.size == 32, "client-identity")
        if (phase != RemoteHarnessCredentialPhase.RESERVED) {
            token(accessToken); token(refreshToken)
            rhCheck(accessExpiresAt > 0 && refreshExpiresAt > 0, "client-expiry")
        }
    }
    fun <T> useSeed(action: (ByteArray) -> T): T {
        val copy = seed.copyOf()
        return try { action(copy) } finally { copy.fill(0) }
    }
    fun replacing(phase: RemoteHarnessCredentialPhase = this.phase, pair: RemoteHarnessClientTokenPair? = null) =
        useSeed { RemoteHarnessClientCredentials(origin, deviceID, it, phase, pair?.accessToken ?: accessToken,
            pair?.accessExpiresAt ?: accessExpiresAt, pair?.refreshToken ?: refreshToken, pair?.refreshExpiresAt ?: refreshExpiresAt) }
    override fun toString() = "RemoteHarnessClientCredentials(redacted)"
    companion object {
        private fun token(value: String?) { rhCheck(value != null && Regex("^[A-Za-z0-9_-]{1,8192}$").matches(value), "client-token") }
    }
}

class RemoteHarnessClientTokenPair(val accessToken: String, val accessExpiresAt: Long,
    val refreshToken: String, val refreshExpiresAt: Long) {
    override fun toString() = "RemoteHarnessClientTokenPair(redacted)"
}

/** A throw or a read-back mismatch must leave the controller blocked. No deletion/reset fallback. */
interface RemoteHarnessClientCredentialStore {
    fun read(): RemoteHarnessClientCredentials?
    fun write(record: RemoteHarnessClientCredentials)
}

class RemoteHarnessClientLogin(val token: String, val expiresAt: Long) {
    override fun toString() = "RemoteHarnessClientLogin(redacted)"
}

class RemoteHarnessClientHost(val deviceID: String, val name: String, val membershipID: String,
    val online: Boolean, val publicKey: ByteArray? = null, val fingerprint: String? = null) {
    init { rhID(deviceID); rhID(name); rhID(membershipID) }
    override fun toString() = "RemoteHarnessClientHost(redacted)"
}

/** Blocking bounded REST seam. Android runs it on the same dedicated owner, never the UI thread. */
interface RemoteHarnessClientAPI {
    fun login(origin: String, email: String, password: CharArray): RemoteHarnessClientLogin
    fun register(record: RemoteHarnessClientCredentials, accountToken: String, publicIdentity: String): RemoteHarnessClientTokenPair
    fun refresh(record: RemoteHarnessClientCredentials): RemoteHarnessClientTokenPair
    fun hosts(record: RemoteHarnessClientCredentials): List<RemoteHarnessClientHost>
    fun host(record: RemoteHarnessClientCredentials, summary: RemoteHarnessClientHost): RemoteHarnessClientHost
    fun revoke(record: RemoteHarnessClientCredentials)
}

interface RemoteHarnessClientSocket {
    fun send(bytes: ByteArray)
    fun checkDeadline(now: Long)
    fun close()
}
interface RemoteHarnessClientSocketListener {
    fun opened()
    fun received(bytes: ByteArray)
    fun closed()
}
/** Listener delivery MUST be on the constructor owner thread; original generation is captured. */
fun interface RemoteHarnessClientSocketFactory {
    fun connect(origin: String, listener: RemoteHarnessClientSocketListener): RemoteHarnessClientSocket
}

data class RemoteHarnessClientWorkspace(val id: String, val title: String, val path: String, val sessionIDs: List<String>) {
    override fun toString() = "RemoteHarnessClientWorkspace(redacted)"
}
data class RemoteHarnessClientSession(val id: String, val title: String, val running: Boolean) {
    override fun toString() = "RemoteHarnessClientSession(redacted)"
}
data class RemoteHarnessClientModel(val provider: String, val id: String, val name: String, val efforts: List<Pair<String, String>>) {
    override fun toString() = "RemoteHarnessClientModel(redacted)"
}
data class RemoteHarnessClientTimelineItem(val id: String, val kind: String, val text: String, val reasoning: String = "") {
    override fun toString() = "RemoteHarnessClientTimelineItem(redacted)"
}
/** Durable restriction only; no Bot display data or mutation authorization is stored. */
data class RemoteHarnessClientBotReadOnlyScope(
    val origin: String, val hostDeviceID: String, val hostFingerprint: String, val workspaceID: String, val sessionID: String,
) {
    init {
        rhCheck(origin == ConnectionOrigins.canonicalize(origin), "client-storage")
        rhID(hostDeviceID); rhID(workspaceID); rhUnicode(sessionID)
        rhCheck(sessionID.isNotEmpty() && '\u0000' !in sessionID &&
            sessionID.toByteArray(Charsets.UTF_8).size <= RemoteHarnessBotRead.IDENTITY_BYTES, "client-storage")
        rhCheck(hostFingerprint.matches(Regex("^[a-f0-9]{64}$")), "client-storage")
    }
    override fun toString() = "RemoteHarnessClientBotReadOnlyScope(redacted)"
}
/** A composer belongs to one pinned Host and destination; null session means a new session. */
data class RemoteHarnessClientDraftScope(
    val origin: String, val hostDeviceID: String, val hostFingerprint: String,
    val workspaceID: String, val sessionID: String?,
) {
    init {
        rhCheck(origin == ConnectionOrigins.canonicalize(origin), "client-storage")
        rhID(hostDeviceID); rhID(workspaceID); sessionID?.let(::rhID)
        rhCheck(hostFingerprint.matches(Regex("^[a-f0-9]{64}$")), "client-storage")
    }
    override fun toString() = "RemoteHarnessClientDraftScope(redacted)"
}
data class RemoteHarnessClientDraft(val scope: RemoteHarnessClientDraftScope, val text: String) {
    init {
        rhUnicode(text)
        rhCheck(text.isNotEmpty() && text.toByteArray(Charsets.UTF_8).size <= RemoteHarnessBounds.TEXT_BYTES, "client-storage")
    }
    override fun toString() = "RemoteHarnessClientDraft(redacted)"
}
enum class RemoteHarnessClientPhase { SETUP, AUTHORIZING, HOSTS, CONFIRM_PIN, CONNECTING, WORKSPACES, SESSIONS, SESSION, DISCONNECTED, BLOCKED }

data class RemoteHarnessClientSnapshot(
    val phase: RemoteHarnessClientPhase = RemoteHarnessClientPhase.SETUP,
    val origin: String = "", val deviceID: String = "", val host: RemoteHarnessClientHost? = null,
    val hosts: List<RemoteHarnessClientHost> = emptyList(), val pendingHost: RemoteHarnessClientHost? = null,
    val workspaces: List<RemoteHarnessClientWorkspace> = emptyList(), val workspaceID: String? = null,
    val workspaceTitle: String = "", val sessions: List<RemoteHarnessClientSession> = emptyList(), val sessionID: String? = null,
    val botSessionReadOnly: Boolean = false,
    val timeline: List<RemoteHarnessClientTimelineItem> = emptyList(), val models: List<RemoteHarnessClientModel> = emptyList(),
    val provider: String? = null, val model: String? = null, val effort: String? = null,
    val draft: String = "", val draftScope: RemoteHarnessClientDraftScope? = null,
    val unsavedScopedDraft: RemoteHarnessClientDraft? = null, val status: RemoteSessionStatus = RemoteSessionStatus.DISCONNECTED,
    val busy: Boolean = false, val error: String? = null, val historyReady: Boolean = false,
    val hasMore: Boolean = false, val approvalSupported: Boolean = false,
    val approvals: List<RemoteHarnessClientApproval> = emptyList(),
    val approvalActions: Map<String, RemoteHarnessClientApprovalAction> = emptyMap(),
    // Connection-local display state. Roster data and navigation authority are never persisted.
    val botReadSupported: Boolean = false, val botRosterLoading: Boolean = false,
    val botRoster: RemoteHarnessBotRoster? = null, val botRosterError: String? = null,
    val availableBotIDs: Set<String> = emptySet(),
    val botSessionClassificationPending: Boolean = false,
    val clientPublicIdentity: String? = null, val clientFingerprint: String? = null,
) {
    override fun toString() = "RemoteHarnessClientSnapshot(redacted)"
}

/** No credential values or private identity bytes may be serialized in this record. */
class RemoteHarnessClientSavedState(
    val origin: String, val deviceID: String, val hostID: String?, val hostName: String?, val hostFingerprint: String?,
    val workspaceID: String?, val workspaceTitle: String, val sessionID: String?, val draft: String,
    val timeline: List<RemoteHarnessClientTimelineItem>, val commands: List<String>,
    val provider: String? = null, val model: String? = null, val effort: String? = null,
    selectedBotReadOnly: Boolean = false,
    botReadOnlyScopes: List<RemoteHarnessClientBotReadOnlyScope>? = null,
    drafts: List<RemoteHarnessClientDraft>? = null,
    // Legacy journal hint only. The controller's independent intent store is authoritative.
    val foregroundReconnectAllowed: Boolean = true,
) {
    val botReadOnlyScopes: List<RemoteHarnessClientBotReadOnlyScope>
    val botSessionReadOnly: Boolean
    val drafts: List<RemoteHarnessClientDraft>
    init {
        rhCheck(origin == ConnectionOrigins.canonicalize(origin), "client-storage"); rhID(deviceID)
        if (hostID != null) { rhID(hostID); rhCheck(hostName != null && hostFingerprint?.matches(Regex("^[a-f0-9]{64}$")) == true, "client-storage") }
        else rhCheck(hostName == null && hostFingerprint == null, "client-storage")
        workspaceID?.let(::rhID); sessionID?.let(::rhID)
        rhCheck(sessionID == null || workspaceID != null && hostID != null, "client-storage")
        rhCheck(!selectedBotReadOnly || sessionID != null && workspaceID != null && hostID != null, "client-storage")
        val currentScope = if (sessionID != null && workspaceID != null && hostID != null && hostFingerprint != null)
            RemoteHarnessClientBotReadOnlyScope(origin, hostID, hostFingerprint, workspaceID, sessionID) else null
        // The short-lived selected-only format is upgraded without dropping its restriction.
        val scopes = botReadOnlyScopes ?: if (selectedBotReadOnly) listOf(currentScope!!) else emptyList()
        rhCheck(scopes.size <= MAX_BOT_READ_ONLY_SCOPES && scopes.distinct().size == scopes.size && scopes.all { it.origin == origin }, "client-storage")
        val selected = currentScope != null && currentScope in scopes
        rhCheck(botReadOnlyScopes == null || selectedBotReadOnly == selected, "client-storage")
        this.botReadOnlyScopes = java.util.Collections.unmodifiableList(ArrayList(scopes))
        this.botSessionReadOnly = selected
        rhCheck(draft.toByteArray(Charsets.UTF_8).size <= RemoteHarnessBounds.TEXT_BYTES && timeline.size <= 512 &&
            commands.size <= 512 && commands.distinct().size == commands.size, "client-storage")
        commands.forEach(::rhID)
        rhUnicode(draft)
        val draftScope = if (hostID != null && hostFingerprint != null && workspaceID != null)
            RemoteHarnessClientDraftScope(origin, hostID, hostFingerprint, workspaceID, sessionID) else null
        // Upgrade the original selected-draft format without guessing another destination.
        val scoped = drafts ?: if (draft.isNotEmpty() && draftScope != null) listOf(RemoteHarnessClientDraft(draftScope, draft)) else emptyList()
        rhCheck(scoped.size <= MAX_DRAFTS && scoped.map { it.scope }.distinct().size == scoped.size &&
            scoped.all { it.scope.origin == origin } && scoped.sumOf { it.text.toByteArray(Charsets.UTF_8).size } <= MAX_DRAFT_BYTES, "client-storage")
        if (drafts != null) rhCheck(draft == (scoped.singleOrNull { it.scope == draftScope }?.text ?: ""), "client-storage")
        this.drafts = java.util.Collections.unmodifiableList(ArrayList(scoped))
    }
    override fun toString() = "RemoteHarnessClientSavedState(redacted)"
    companion object {
        const val MAX_BOT_READ_ONLY_SCOPES = 128
        const val MAX_DRAFTS = 32
        const val MAX_DRAFT_BYTES = 1_048_576
    }
}
interface RemoteHarnessClientStateStore {
    fun read(): RemoteHarnessClientSavedState?
    fun write(state: RemoteHarnessClientSavedState)
}

/** User recovery intent must remain writable when the transcript/draft journal is full.
 * Missing state returns false; failed reads/writes throw rather than claiming persistence. */
interface RemoteHarnessClientRecoveryIntentStore {
    fun read(): Boolean
    fun write(allowed: Boolean)
}

/** Versioned explicit codecs are shared with the JVM controller fixtures. */
object RemoteHarnessClientRecords {
    private fun Map<String, RemoteHarnessJSON>.s(name: String) = get(name)?.let { if (it === RemoteHarnessJSON.NullValue) null else it.stringValue() }
    fun credentials(record: RemoteHarnessClientCredentials): String = record.useSeed { seed ->
        RemoteHarnessJSON.write(RemoteHarnessJSON.obj("v" to RemoteHarnessJSON.num(1), "role" to RemoteHarnessJSON.str("client"),
            "origin" to RemoteHarnessJSON.str(record.origin), "deviceId" to RemoteHarnessJSON.str(record.deviceID),
            "seed" to RemoteHarnessJSON.str(Base64.getUrlEncoder().withoutPadding().encodeToString(seed)),
            "phase" to RemoteHarnessJSON.str(record.phase.name), "accessToken" to record.accessToken?.let(RemoteHarnessJSON::str),
            "accessExpiresAt" to RemoteHarnessJSON.num(record.accessExpiresAt), "refreshToken" to record.refreshToken?.let(RemoteHarnessJSON::str),
            "refreshExpiresAt" to RemoteHarnessJSON.num(record.refreshExpiresAt)))
    }
    fun credentials(source: String): RemoteHarnessClientCredentials {
        rhCheck(source.toByteArray().size <= 65_536, "client-storage")
        val p = RemoteHarnessJSON.parse(source).objectValue()
        rhCheck(p.rhRequired("v").integerValue() == 1L && p.rhString("role") == "client", "client-storage")
        val seed = Base64.getUrlDecoder().decode(p.rhString("seed"))
        return try { RemoteHarnessClientCredentials(p.rhString("origin"), p.rhString("deviceId"), seed,
            RemoteHarnessCredentialPhase.valueOf(p.rhString("phase")), p.s("accessToken"), p.rhRequired("accessExpiresAt").integerValue(),
            p.s("refreshToken"), p.rhRequired("refreshExpiresAt").integerValue()) } finally { seed.fill(0) }
    }
    fun state(record: RemoteHarnessClientSavedState): String {
        fun s(v: String?) = v?.let(RemoteHarnessJSON::str)
        return RemoteHarnessJSON.write(RemoteHarnessJSON.obj("v" to RemoteHarnessJSON.num(1),
            "origin" to s(record.origin), "deviceId" to s(record.deviceID), "hostId" to s(record.hostID),
            "hostName" to s(record.hostName), "pin" to s(record.hostFingerprint), "workspaceId" to s(record.workspaceID),
            "workspaceTitle" to s(record.workspaceTitle), "sessionId" to s(record.sessionID), "draft" to s(record.draft),
            "drafts" to RemoteHarnessJSON.ArrayValue(record.drafts.map { draft ->
                RemoteHarnessJSON.obj("origin" to s(draft.scope.origin), "hostDeviceId" to s(draft.scope.hostDeviceID),
                    "hostFingerprint" to s(draft.scope.hostFingerprint), "workspaceId" to s(draft.scope.workspaceID),
                    "sessionId" to (s(draft.scope.sessionID) ?: RemoteHarnessJSON.NullValue), "text" to s(draft.text))
            }),
            "foregroundReconnectAllowed" to RemoteHarnessJSON.BooleanValue(record.foregroundReconnectAllowed),
            "botSessionReadOnly" to RemoteHarnessJSON.BooleanValue(record.botSessionReadOnly),
            "botReadOnlyScopes" to RemoteHarnessJSON.ArrayValue(record.botReadOnlyScopes.map { scope ->
                RemoteHarnessJSON.obj("origin" to s(scope.origin), "hostDeviceId" to s(scope.hostDeviceID),
                    "hostFingerprint" to s(scope.hostFingerprint), "workspaceId" to s(scope.workspaceID), "sessionId" to s(scope.sessionID))
            }),
            "provider" to s(record.provider), "model" to s(record.model), "effort" to s(record.effort),
            "timeline" to RemoteHarnessJSON.ArrayValue(record.timeline.map { RemoteHarnessJSON.obj("id" to s(it.id),
                "kind" to s(it.kind), "text" to s(it.text), "reasoning" to s(it.reasoning)) }),
            "commands" to RemoteHarnessJSON.ArrayValue(record.commands.map(RemoteHarnessJSON::str))))
    }
    fun state(source: String): RemoteHarnessClientSavedState {
        val p = RemoteHarnessJSON.parse(source).objectValue(); rhCheck(p.rhRequired("v").integerValue() == 1L, "client-storage")
        val timeline = (p.rhRequired("timeline") as RemoteHarnessJSON.ArrayValue).values.map { value ->
            val item = value.objectValue(); RemoteHarnessClientTimelineItem(item.rhString("id"), item.rhString("kind"), item.rhString("text"), item.rhString("reasoning")) }
        val commands = (p.rhRequired("commands") as RemoteHarnessJSON.ArrayValue).values.map { it.stringValue() }
        val scopes = p["botReadOnlyScopes"]?.let { value ->
            val rows = value as? RemoteHarnessJSON.ArrayValue ?: throw RemoteHarnessException("client-storage")
            rhCheck(rows.values.size <= RemoteHarnessClientSavedState.MAX_BOT_READ_ONLY_SCOPES, "client-storage")
            rows.values.map { row ->
                val scope = row.objectValue()
                rhCheck(scope.keys == setOf("origin", "hostDeviceId", "hostFingerprint", "workspaceId", "sessionId"), "client-storage")
                RemoteHarnessClientBotReadOnlyScope(scope.rhString("origin"), scope.rhString("hostDeviceId"),
                    scope.rhString("hostFingerprint"), scope.rhString("workspaceId"), scope.rhString("sessionId"))
            }
        }
        val drafts = p["drafts"]?.let { value ->
            val rows = value as? RemoteHarnessJSON.ArrayValue ?: throw RemoteHarnessException("client-storage")
            rhCheck(rows.values.size <= RemoteHarnessClientSavedState.MAX_DRAFTS, "client-storage")
            rows.values.map { row ->
                val fields = row.objectValue()
                rhCheck(fields.keys == setOf("origin", "hostDeviceId", "hostFingerprint", "workspaceId", "sessionId", "text"), "client-storage")
                RemoteHarnessClientDraft(RemoteHarnessClientDraftScope(fields.rhString("origin"), fields.rhString("hostDeviceId"),
                    fields.rhString("hostFingerprint"), fields.rhString("workspaceId"), fields.s("sessionId")), fields.rhString("text"))
            }
        }
        rhCheck(timeline.size <= 512 && commands.size <= 512 && p.rhString("draft").toByteArray().size <= RemoteHarnessBounds.TEXT_BYTES, "client-storage")
        return RemoteHarnessClientSavedState(p.rhString("origin"), p.rhString("deviceId"), p.s("hostId"), p.s("hostName"), p.s("pin"),
            p.s("workspaceId"), p.rhString("workspaceTitle"), p.s("sessionId"), p.rhString("draft"), timeline, commands,
            p.s("provider"), p.s("model"), p.s("effort"), p["botSessionReadOnly"]?.booleanValue() ?: false, scopes, drafts,
            p["foregroundReconnectAllowed"]?.booleanValue() ?: true)
    }
    fun fingerprint(key: ByteArray): String {
        rhCheck(key.size == 32, "client-host-key")
        return MessageDigest.getInstance("SHA-256").digest(key).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
