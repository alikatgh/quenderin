package ai.quenderin.core

/**
 * Decides WHEN a streaming reply's partial text is pushed into the transcript (and therefore
 * recomposed), instead of once per token.
 *
 * Why: every transcript write copies the message list, re-parses the whole reply's Markdown
 * (`remember(text)` misses on every token while the text grows) and posts a main-thread hop. At
 * 30–80 tok/s that — not the engine — is the jank users attribute to "the model". Cloud chat UIs
 * coalesce tokens to display frames; so do we: the first piece lands immediately (the bubble must
 * show text the instant the model speaks), then at most one write per [intervalNanos] (~30 Hz),
 * then the settle write at the end. The engine still streams token by token — only the UI write is
 * paced. Pure (inject `now`) so it verifies without a clock. Swift twin: `StreamFlushGate.swift`.
 */
class StreamFlushGate(private val intervalNanos: Long = DEFAULT_INTERVAL_NANOS) {
    private var lastFlushNanos: Long? = null

    /** True when the partial text should be written now: always for the first piece, then only once
     *  the interval has elapsed since the last write. Records the flush when it returns true. */
    fun shouldFlush(nowNanos: Long = System.nanoTime()): Boolean {
        val last = lastFlushNanos
        if (last != null && nowNanos - last < intervalNanos) return false
        lastFlushNanos = nowNanos
        return true
    }

    companion object {
        /** ~30 writes/s: one display frame at 30 Hz, and finer than anyone reads. */
        const val DEFAULT_INTERVAL_NANOS: Long = 33_000_000L
    }
}
