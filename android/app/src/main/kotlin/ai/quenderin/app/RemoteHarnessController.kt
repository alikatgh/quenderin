package ai.quenderin.app

import ai.quenderin.core.*
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Activity composition owns this facade; its dedicated executor owns BOTH Noise and business RPC.
 * UI state returns to Main. HTTP, crypto, persistence and every generation callback stay off Main. */
class RemoteHarnessController(context: Context) : AutoCloseable {
    var state by mutableStateOf(RemoteHarnessClientSnapshot()); private set
    var securityAvailable by mutableStateOf(false); private set
    private val main = Handler(Looper.getMainLooper())
    private val owner = ScheduledThreadPoolExecutor(1) { run -> Thread(run, "quenderin-remote-owner").apply { isDaemon = true } }
        .apply { removeOnCancelPolicy = true }
    private var client: RemoteHarnessClient? = null
    @Volatile private var closed = false
    var inputError by mutableStateOf<String?>(null); private set
    private val inputs = RemoteHarnessClientInputQueue(
        schedule = { action -> owner.execute(action) },
        applyDraft = { scope, text -> client?.draft(text, scope) },
    )
    private val foregroundQueued = java.util.concurrent.atomic.AtomicBoolean(false)
    private val presentationStore = context.applicationContext.getSharedPreferences("remote-presentation", Context.MODE_PRIVATE)
    var wrapCode by mutableStateOf(presentationStore.getBoolean("wrapCode", true)); private set
    var largeText by mutableStateOf(presentationStore.getBoolean("largeText", false)); private set
    fun wrapCode(value: Boolean) { wrapCode = value; presentationStore.edit().putBoolean("wrapCode", value).apply() }
    fun largeText(value: Boolean) { largeText = value; presentationStore.edit().putBoolean("largeText", value).apply() }
    init {
        val application = context.applicationContext
        owner.execute {
            val backend = RemoteHarnessCryptoBackends.native()
            main.post { if (!closed) securityAvailable = backend.isAvailable }
            val clock = object : RemoteHarnessClock {
                override fun epochMilliseconds() = System.currentTimeMillis()
                override fun monotonicMilliseconds() = SystemClock.elapsedRealtime()
            }
            client = RemoteHarnessClient(RemoteHarnessOkHttpAPI(), AndroidRemoteHarnessCredentials(application),
                AndroidRemoteHarnessState(application), RemoteHarnessOkHttpSockets({ action ->
                    if (!closed) owner.execute(action)
                }, clock::monotonicMilliseconds), backend, clock,
                { ByteArray(32).also(SecureRandom()::nextBytes) }, { UUID.randomUUID().toString() },
                AndroidRemoteHarnessRecoveryIntent(application)).also { model ->
                model.onChange = { next -> main.post { if (!closed) state = next } }
                val next = model.snapshot; main.post { if (!closed) state = next }
            }
        }
        owner.scheduleAtFixedRate({ if (!closed) client?.tick() }, 250, 250, TimeUnit.MILLISECONDS)
    }
    private fun dispatch(action: (RemoteHarnessClient) -> Unit): Boolean {
        if (closed) return false
        val accepted = inputs.command { client?.let(action) }
        if (!accepted) inputError = "Too many queued actions. Wait for the computer connection before trying again."
        return accepted
    }
    fun authorize(origin: String, email: String, password: CharArray) {
        if (!dispatch { it.authorize(origin, email, password) }) password.fill('\u0000')
    }
    private fun navigate(action: (RemoteHarnessClient) -> Unit) { dispatch(action) }
    fun foreground() {
        if (closed || !foregroundQueued.compareAndSet(false, true)) return
        if (!dispatch { model -> try { model.foreground() } finally { foregroundQueued.set(false) } }) foregroundQueued.set(false)
    }
    fun reconnect() = navigate(RemoteHarnessClient::resume)
    fun hosts() = navigate(RemoteHarnessClient::refreshHosts)
    fun chooseHost(id: String) = navigate { it.chooseHost(id) }
    fun confirmHost(pin: String) = navigate { it.confirmHost(pin) }
    fun workspace(id: String) = navigate { it.chooseWorkspace(id) }
    fun session(id: String) = navigate { it.chooseSession(id) }
    fun refreshBots() { dispatch(RemoteHarnessClient::refreshBotRoster) }
    fun bot(id: String) = navigate { it.chooseBot(id) }
    fun createSession() = navigate(RemoteHarnessClient::createSession)
    fun selectModel(provider: String, model: String, effort: String?) { dispatch { it.selectModel(provider, model, effort) } }
    fun draft(value: String, scope: RemoteHarnessClientDraftScope?) {
        if (closed || scope != state.draftScope) return
        val accepted = inputs.draft(scope, value)
        inputError = if (accepted) null else "This draft is not saved yet. Keep the text here and wait before trying again."
    }
    fun send(scope: RemoteHarnessClientDraftScope?, text: String) {
        if (closed || scope != state.draftScope) return
        // Reaccept the visible text before sealing Send; rejected drafts can never send an older value.
        if (!inputs.draft(scope, text)) {
            inputError = "This draft is not saved yet. Keep the text here and wait before trying again."
            return
        }
        inputError = null
        dispatch { it.send(scope) }
    }
    fun stop() { dispatch(RemoteHarnessClient::stop) }
    fun decideApproval(eventID: String, allowedOnce: Boolean) { dispatch { it.decideApproval(eventID, allowedOnce) } }
    fun earlierHistory() { dispatch(RemoteHarnessClient::earlierHistory) }
    fun disconnect() = navigate(RemoteHarnessClient::disconnect)
    fun revokeDevice() { dispatch(RemoteHarnessClient::revokeDevice) }
    override fun close() {
        if (closed) return
        closed = true
        owner.execute { client?.close(); client = null }
        owner.shutdown()
    }
}
