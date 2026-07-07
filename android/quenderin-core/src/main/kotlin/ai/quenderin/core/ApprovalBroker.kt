package ai.quenderin.core

/**
 * Bridges the runner's synchronous "may I?" to a Compose dialog — the Kotlin twin of iOS
 * `ApprovalBroker`. The agent runs on a background thread (Dispatchers.IO), so [request] can
 * simply BLOCK that thread until the user answers on the main thread; Compose observes
 * [onRequest] to show the Allow / Don't-allow dialog and calls [answer].
 *
 * One question at a time (the agent loop is sequential). Dismissal without answering must call
 * `answer(false)` — the safe reading of silence. A hard-stop while a question is open should
 * call [cancelPending] so the blocked run ends as a decline instead of waiting forever.
 */
class ApprovalBroker {
    /** The app marshals this onto the main thread and shows the dialog. Fired from the agent's
     *  background thread. */
    var onRequest: (ActionPreview) -> Unit = {}

    private val lock = java.util.concurrent.locks.ReentrantLock()
    private val answered = lock.newCondition()
    private var pending = false
    private var verdict: Boolean? = null

    /** Called by the runner (the agent's thread). Blocks until [answer] / [cancelPending]. */
    fun request(preview: ActionPreview): Boolean {
        lock.lock()
        try {
            pending = true
            verdict = null
            onRequest(preview)
            // await() releases the lock so the main thread's answer() can enter. A same-thread
            // answer from inside onRequest (tests) also works — the lock is reentrant and the
            // loop below sees the verdict without ever waiting.
            while (verdict == null) answered.await()
            pending = false
            return verdict!!
        } finally {
            lock.unlock()
        }
    }

    /** The user's answer (or `false` on dialog dismissal). Ignored when nothing is pending. */
    fun answer(approved: Boolean) {
        lock.lock()
        try {
            if (!pending) return
            verdict = approved
            answered.signalAll()
        } finally {
            lock.unlock()
        }
    }

    /** FAIL-CLOSED release for a hard-stop: an open question is answered NO so the blocked run
     *  can end instead of waiting on a dialog nobody will answer. */
    fun cancelPending() = answer(false)
}
