package ai.quenderin.app

import ai.quenderin.core.*
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class DeepSeekTranscriptRow(val role: ProviderRole, val text: String, val reasoning: String?) {
    override fun toString() = "DeepSeekTranscriptRow(redacted)"
}
class DeepSeekThread(val id: String, val title: String) {
    override fun toString() = "DeepSeekThread(redacted)"
}
class DeepSeekUiState(
    val ready: Boolean = false,
    val connected: Boolean = false,
    val busy: Boolean = false,
    val streaming: Boolean = false,
    val model: String = DeepSeekCatalog.DEFAULT_MODEL,
    val effort: ReasoningEffort = ReasoningEffort.HIGH,
    val rows: List<DeepSeekTranscriptRow> = emptyList(),
    val partial: String = "",
    val partialReasoning: String = "",
    val incomplete: Boolean = false,
    val threads: List<DeepSeekThread> = emptyList(),
    val currentID: String? = null,
    val usage: DeepSeekUsage? = null,
    val message: String? = null,
) { override fun toString() = "DeepSeekUiState(redacted)" }

/** Single owner of the cloud journey. Injectable seams permit fixture-only validation.
 * Every external call is an explicit user action. Nothing consumes the local chat store or tools. */
class DeepSeekController(
    private val vault: DeepSeekCredentialVault,
    private val transport: DeepSeekTransport,
    private val persistence: DeepSeekPersistence,
) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val mutableState = MutableStateFlow(DeepSeekUiState())
    val state: StateFlow<DeepSeekUiState> = mutableState
    private var profile: ConnectionProfile? = null
    private var model = DeepSeekCatalog.DEFAULT_MODEL
    private var effort = ReasoningEffort.HIGH
    private var threads = mutableListOf<DeepSeekConversation>()
    private var current: DeepSeekConversation? = null
    private var busy = false
    private var streaming = false
    private var ready = false
    private var generation = 0L
    private var usage: DeepSeekUsage? = null
    private var message: String? = null
    private var closed = false
    private var activeCancellation: DeepSeekCancellation? = null

    init {
        scope.launch {
            synchronized(lock) {
                try {
                    profile = persistence.readProfile()
                    threads = persistence.readConversations().toMutableList()
                    current = threads.firstOrNull()
                    current?.envelope?.selection?.let { saved ->
                        if (saved.modelID in DeepSeekCatalog.models) model = saved.modelID
                        effort = saved.reasoningEffort
                    }
                    if (current?.incomplete == true) message = DeepSeekFailure.INCOMPLETE.userMessage
                    ready = true
                } catch (_: Exception) { ready = false; profile = null; message = DeepSeekFailure.STORAGE.userMessage }
                publish()
            }
        }
    }

    fun selectModel(selected: String) = synchronized(lock) {
        if (!busy && selected in DeepSeekCatalog.models && (current == null || current!!.envelope.messages.isEmpty())) {
            model = selected; publish()
        }
    }
    fun selectEffort(selected: ReasoningEffort) = synchronized(lock) {
        if (!busy) { effort = selected; publish() }
    }

    /** Caller immediately clears the UI field; this owned char array is wiped on every exit. */
    fun connect(key: CharArray) {
        val cancellation = DeepSeekCancellation()
        val ticket = synchronized(lock) {
            if (closed || busy || !ready) { key.fill('\u0000'); return }
            activeCancellation = cancellation; busy = true; message = null; publish(); ++generation
        }
        scope.launch {
            var created: String? = null
            var profileWriteAttempted = false
            try {
                val createdReference = vault.save(key)
                created = createdReference
                key.fill('\u0000')
                val models = transport.models(createdReference, cancellation)
                synchronized(lock) {
                    if (closed || ticket != generation) throw DeepSeekException(DeepSeekFailure.CANCELLED)
                    if (model !in models) throw DeepSeekException(DeepSeekFailure.MODEL)
                    val previous = profile?.credentialReference
                    val next = DeepSeekCatalog.profile(createdReference)
                    profileWriteAttempted = true
                    persistence.writeProfile(next)
                    profile = next
                    created = null // Ownership transfers only after profile commit.
                    if (previous != null && previous != next.credentialReference) {
                        try { vault.remove(previous) } catch (_: Exception) { message = "Connected. The previous encrypted credential could not be removed; try Remove key." }
                    }
                    if (message == null) message = "Connected using the free models check. No chat request was sent."
                }
            } catch (e: Exception) {
                synchronized(lock) {
                    if (!closed && ticket == generation) {
                        message = safeFailure(e).userMessage
                        // The installed account is uncertain after a profile commit error. Keep all
                        // references, but require a fresh durable read before admitting more work.
                        if (profileWriteAttempted) ready = false
                    }
                }
            } finally {
                key.fill('\u0000')
                // A write can report failure after installing the new reference. Keep its encrypted
                // key in that uncertain case; deleting it could strand a committed profile on relaunch.
                if (!profileWriteAttempted) created?.let { try { vault.remove(it) } catch (_: Exception) {} }
                synchronized(lock) { if (ticket == generation) { busy = false; activeCancellation = null; publish() } }
            }
        }.invokeOnCompletion { key.fill('\u0000') }
    }

    fun removeKey() {
        synchronized(lock) { if (closed || busy || !ready) return; busy = true; message = null; publish() }
        scope.launch {
            synchronized(lock) {
                try {
                    vault.removeAll()
                    persistence.writeProfile(null); profile = null
                    message = "API key removed from this device. Saved cloud conversations stay on this device."
                } catch (_: Exception) { message = DeepSeekFailure.STORAGE.userMessage }
                busy = false; publish()
            }
        }
    }

    /** Consent is an explicit action on every new cloud thread, separate from local chat consent. */
    fun newConversation(consented: Boolean): Unit = synchronized(lock) {
        if (!consented || closed || busy || !ready) return
        val destination = profile ?: return
        if (threads.size >= DeepSeekCatalog.MAX_CONVERSATIONS) {
            message = "The on-device cloud history limit is 30 conversations."; publish(); return
        }
        try {
            val next = DeepSeekConversation.new(destination, UUID.randomUUID().toString(), DeepSeekCatalog.selection(model, effort))
            persistence.writeConversation(next)
            threads.add(0, next); current = next; usage = null; message = null
        } catch (_: Exception) { message = DeepSeekFailure.STORAGE.userMessage }
        publish()
    }

    fun openConversation(id: String): Unit = synchronized(lock) {
        if (closed || busy) return
        threads.firstOrNull { it.envelope.conversationID == id }?.let {
            current = it; model = it.envelope.selection?.modelID ?: DeepSeekCatalog.DEFAULT_MODEL
            effort = it.envelope.selection?.reasoningEffort ?: ReasoningEffort.HIGH
            usage = null; message = if (it.incomplete) DeepSeekFailure.INCOMPLETE.userMessage else null; publish()
        }
    }

    fun send(text: String) {
        val cancellation = DeepSeekCancellation()
        val ticket: Long
        val conversation: DeepSeekConversation
        val destination: ConnectionProfile
        synchronized(lock) {
            if (closed || busy || !ready || text.isBlank()) return
            destination = profile ?: return
            conversation = current ?: return
            if (conversation.incomplete) { message = DeepSeekFailure.INCOMPLETE.userMessage; publish(); return }
            activeCancellation = cancellation; busy = true; streaming = true; message = null; usage = null; ticket = ++generation; publish()
        }
        scope.launch {
            try {
                val request = synchronized(lock) {
                    if (closed || ticket != generation) throw DeepSeekException(DeepSeekFailure.CANCELLED)
                    cancellation.check()
                    val request = conversation.begin(destination, text, DeepSeekCatalog.selection(model, effort),
                        System.currentTimeMillis(), UUID.randomUUID().toString())
                    // Persist the incomplete turn before opening the paid request. A failed save stops dispatch.
                    persistence.writeConversation(conversation); publish(); request
                }
                var lastPersist = System.nanoTime()
                val reply = transport.stream(destination.credentialReference ?: throw DeepSeekException(DeepSeekFailure.CREDENTIAL), request, cancellation) { event ->
                    synchronized(lock) {
                        if (closed || ticket != generation) throw DeepSeekException(DeepSeekFailure.CANCELLED)
                        cancellation.check()
                        conversation.event(event)
                        if (event is ProviderEvent.Usage) usage = DeepSeekUsage(event.inputTokens, event.outputTokens)
                        val now = System.nanoTime()
                        if (now - lastPersist >= 1_000_000_000L) { persistence.writeConversation(conversation); lastPersist = now }
                        publish()
                    }
                }
                synchronized(lock) {
                    if (!closed && ticket == generation) {
                        cancellation.check()
                        conversation.complete(reply)
                        streaming = false // Completion and stop eligibility change under the same lock.
                        persistence.writeConversation(conversation)
                        usage = reply.usage
                        if (!reply.complete) message = "The output limit was reached. Start a new conversation; this partial reply will not be sent as complete."
                    }
                }
            } catch (e: Exception) {
                synchronized(lock) {
                    if (!closed && ticket == generation) {
                        conversation.interrupt()
                        streaming = false
                        message = safeFailure(e).userMessage
                        try { persistence.writeConversation(conversation) } catch (_: Exception) { message = DeepSeekFailure.STORAGE.userMessage }
                    }
                }
            } finally {
                synchronized(lock) { if (ticket == generation) { busy = false; streaming = false; activeCancellation = null; publish() } }
            }
        }
    }

    fun stop() {
        synchronized(lock) {
            if (!streaming) return
            activeCancellation?.cancel()
            current?.let {
                it.interrupt()
                try { persistence.writeConversation(it) } catch (_: Exception) { message = DeepSeekFailure.STORAGE.userMessage }
            }
            streaming = false // busy remains true until the exact cancelled operation terminates.
            if (message != DeepSeekFailure.STORAGE.userMessage) message = DeepSeekFailure.CANCELLED.userMessage
            publish()
        }
    }

    override fun close() {
        stop()
        synchronized(lock) { closed = true; ++generation; activeCancellation?.cancel() }
        transport.cancel(); scope.cancel()
    }

    private fun safeFailure(error: Exception) = (error as? DeepSeekException)?.failure ?: DeepSeekFailure.CONNECTION
    private fun publish() {
        val conversation = current
        mutableState.value = DeepSeekUiState(ready, profile != null, busy, streaming, model, effort,
            conversation?.envelope?.messages?.map { DeepSeekTranscriptRow(it.role, it.content, it.reasoningContent) } ?: emptyList(),
            conversation?.partial ?: "", conversation?.partialReasoning ?: "", conversation?.incomplete ?: false,
            threads.map { thread -> DeepSeekThread(thread.envelope.conversationID,
                thread.envelope.messages.firstOrNull { it.role == ProviderRole.USER }?.content?.take(60) ?: "New cloud conversation") },
            conversation?.envelope?.conversationID, usage, message)
    }
}
