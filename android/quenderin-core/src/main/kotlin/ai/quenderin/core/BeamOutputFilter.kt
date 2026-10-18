package ai.quenderin.core

/** Incremental final-only Beam Harmony wire parser. Prompt ends in `<|start|>assistant`, so generation
 * starts with a channel header. Private reasoning, commentary and tools never reach chat UI.
 * Headers/control fragments are bounded; malformed framing fails closed through the token cap. */
internal class BeamOutputFilter(private val emit: (String) -> Unit) {
    private enum class State { HEADER, BODY, NEXT_ASSISTANT, DONE, FAILED }
    private var state = State.HEADER
    private val pending = StringBuilder()
    private var visible = false
    private val header = Regex("^\\s*<\\|channel\\|>(analysis|final)\\s*$")

    fun accept(piece: String) {
        if (state == State.DONE || state == State.FAILED) return
        // Native calls deliver token pieces, but bound even a malicious oversized callback.
        for (chunk in piece.chunked(256)) {
            pending.append(chunk)
            drain()
            if (state == State.DONE || state == State.FAILED) { pending.setLength(0); return }
        }
    }

    fun finish() {
        // A partial control delimiter/header must not escape on token-cap/cancel. Plain final
        // text has already streamed; the only retained body text can be a `<` prefix.
        pending.setLength(0)
        state = State.DONE
    }

    private fun fail() { pending.setLength(0); state = State.FAILED }

    private fun drain() {
        while (pending.isNotEmpty()) {
            when (state) {
                State.HEADER -> {
                    val end = pending.indexOf("<|message|>")
                    if (end < 0) { if (pending.length > 512) fail(); return }
                    val match = header.matchEntire(pending.substring(0, end))
                    if (match == null || end > 512) { fail(); return }
                    visible = match.groupValues[1].let { it == "final" }
                    pending.delete(0, end + "<|message|>".length)
                    state = State.BODY
                }
                State.BODY -> {
                    val start = pending.indexOf("<|")
                    if (start < 0) {
                        val keep = if (pending.last() == '<') 1 else 0
                        val count = pending.length - keep
                        if (visible && count > 0) emit(pending.substring(0, count))
                        pending.delete(0, count)
                        return
                    }
                    if (start > 0) {
                        if (visible) emit(pending.substring(0, start))
                        pending.delete(0, start)
                    }
                    val end = pending.indexOf("|>")
                    if (end < 0) { if (pending.length > 128) fail(); return }
                    val token = pending.substring(0, end + 2)
                    pending.delete(0, end + 2)
                    when (token) {
                        "<|end|>" -> state = State.NEXT_ASSISTANT
                        "<|return|>" -> { state = State.DONE; pending.setLength(0); return }
                        else -> { fail(); return }
                    }
                }
                State.NEXT_ASSISTANT -> {
                    val expected = "<|start|>assistant"
                    if (pending.length < expected.length) {
                        if (!expected.startsWith(pending.toString())) fail()
                        return
                    }
                    if (!pending.startsWith(expected)) { fail(); return }
                    pending.delete(0, expected.length)
                    state = State.HEADER
                }
                State.DONE, State.FAILED -> { pending.setLength(0); return }
            }
        }
    }

    companion object {
        fun finalText(wire: String): String = buildString {
            val filter = BeamOutputFilter { append(it) }
            filter.accept(wire)
            filter.finish()
        }
    }
}
