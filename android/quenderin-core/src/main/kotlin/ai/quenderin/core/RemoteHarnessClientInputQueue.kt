package ai.quenderin.core

/** Bounded facade scheduling seam. The injected FIFO executor owns effects.
 * A command seals the preceding edit batch. Later edits get another batch, so they cannot
 * replace the text latched before Send or be overwritten by a stale captured edit. */
class RemoteHarnessClientInputQueue(
    private val schedule: (() -> Unit) -> Unit,
    private val applyDraft: (RemoteHarnessClientDraftScope?, String) -> Unit,
) {
    private class Batch(val scope: RemoteHarnessClientDraftScope?, var text: String)
    private val lock = Any()
    private var pending: Batch? = null
    private var editBatches = 0
    private var commands = 0

    /** False rejects before acceptance; the facade retains the editor and shows an error. */
    fun draft(scope: RemoteHarnessClientDraftScope?, text: String): Boolean = synchronized(lock) {
        if (text.length > RemoteHarnessBounds.TEXT_BYTES || text.toByteArray(Charsets.UTF_8).size > RemoteHarnessBounds.TEXT_BYTES) return@synchronized false
        val tail = pending
        if (tail != null && tail.scope == scope) { tail.text = text; return@synchronized true }
        if (editBatches >= MAX_EDIT_BATCHES) return@synchronized false
        val batch = Batch(scope, text)
        pending = batch; editBatches++
        try {
            schedule {
                val latest = synchronized(lock) {
                    if (pending === batch) pending = null
                    batch.text
                }
                try { applyDraft(batch.scope, latest) } finally { synchronized(lock) { editBatches-- } }
            }
        } catch (error: Exception) {
            if (pending === batch) pending = null
            editBatches--
            throw error
        }
        true
    }

    /** Commands and batches share one FIFO executor; no command captures a draft string. */
    fun command(action: () -> Unit): Boolean = synchronized(lock) {
        if (commands >= MAX_COMMANDS) return@synchronized false
        val previous = pending
        pending = null; commands++
        try {
            schedule { try { action() } finally { synchronized(lock) { commands-- } } }
        } catch (error: Exception) {
            pending = previous; commands--
            throw error
        }
        true
    }
    companion object {
        const val MAX_COMMANDS = 32
        const val MAX_EDIT_BATCHES = 33
    }
}
