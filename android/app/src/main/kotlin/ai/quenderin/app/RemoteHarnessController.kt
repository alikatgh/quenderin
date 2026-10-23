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
import java.util.concurrent.atomic.AtomicReference

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
    private val pendingDraft = AtomicReference<String?>()
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
                { ByteArray(32).also(SecureRandom()::nextBytes) }, { UUID.randomUUID().toString() }).also { model ->
                model.onChange = { next -> main.post { if (!closed) state = next } }
                val next = model.snapshot; main.post { if (!closed) state = next }
            }
        }
        owner.scheduleAtFixedRate({ if (!closed) client?.tick() }, 250, 250, TimeUnit.MILLISECONDS)
    }
    private fun dispatch(action: (RemoteHarnessClient) -> Unit) {
        if (!closed) owner.execute { client?.let(action) }
    }
    fun authorize(origin: String, email: String, password: CharArray) {
        if (closed) { password.fill('\u0000'); return }
        dispatch { it.authorize(origin, email, password) }
    }
    fun reconnect() = dispatch(RemoteHarnessClient::resume)
    fun hosts() = dispatch(RemoteHarnessClient::refreshHosts)
    fun chooseHost(id: String) = dispatch { it.chooseHost(id) }
    fun confirmHost(pin: String) = dispatch { it.confirmHost(pin) }
    fun workspace(id: String) = dispatch { it.chooseWorkspace(id) }
    fun session(id: String) = dispatch { it.chooseSession(id) }
    fun createSession() = dispatch(RemoteHarnessClient::createSession)
    fun selectModel(provider: String, model: String, effort: String?) = dispatch { it.selectModel(provider, model, effort) }
    fun draft(value: String) {
        if (closed) return
        // One coalesced queued draft write bounds rapid IME callbacks without losing the latest text.
        if (pendingDraft.getAndSet(value) == null) dispatch { model ->
            pendingDraft.getAndSet(null)?.let(model::draft)
        }
    }
    fun send() = dispatch { model -> pendingDraft.getAndSet(null)?.let(model::draft); model.send() }
    fun stop() = dispatch(RemoteHarnessClient::stop)
    fun decideApproval(eventID: String, allowedOnce: Boolean) = dispatch { it.decideApproval(eventID, allowedOnce) }
    fun earlierHistory() = dispatch(RemoteHarnessClient::earlierHistory)
    fun disconnect() = dispatch(RemoteHarnessClient::disconnect)
    fun revokeDevice() = dispatch(RemoteHarnessClient::revokeDevice)
    override fun close() {
        if (closed) return
        closed = true
        owner.execute { client?.let { model -> pendingDraft.getAndSet(null)?.let(model::draft); model.disconnect() }; client = null }
        owner.shutdown()
    }
}
