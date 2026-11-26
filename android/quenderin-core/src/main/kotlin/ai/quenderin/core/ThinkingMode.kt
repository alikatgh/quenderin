package ai.quenderin.core

/**
 * Controls how reasoning models (Qwen3, DeepSeek-R1, …) handle `<think>…</think>` chains.
 * Semantics mirror Ollama's `think` / `--hidethinking`:
 * - [OFF]: default today — the chat template closes an empty think block for direct replies.
 * - [SHOW]: model is allowed to think; thinking text is shown collapsed above the answer.
 * - [HIDE]: model is allowed to think; only the answer is shown.
 * Pure + deterministic → twin of Swift `ThinkingMode`.
 */
enum class ThinkingMode(val rawValue: String) {
    OFF("off"),
    SHOW("show"),
    HIDE("hide");

    /** Whether the model is allowed to emit reasoning inside `<think>…</think>`. */
    val allowsThinking: Boolean
        get() = this != OFF

    companion object {
        val DEFAULT: ThinkingMode = OFF

        fun fromRawValue(raw: String): ThinkingMode? =
            entries.firstOrNull { it.rawValue == raw }

        /**
         * Returns true when a GGUF chat template gates reasoning via `enable_thinking` or `<think>`.
         * Twin of Swift `ThinkingMode.supports(template:)`.
         */
        fun supports(template: String): Boolean =
            template.contains("enable_thinking") || template.contains("<think>")
    }
}

/**
 * Streaming splitter that separates `<think>…</think>` reasoning from the visible answer across
 * arbitrary token boundaries. Holds back only a possible partial tag suffix (like
 * `StopSequenceScanner`), holds leading ASCII whitespace until the first non-whitespace char
 * (dropping it if `<think>` follows, or emitting it verbatim into `answer` otherwise), supports
 * pre-opened templates ([startsInsideThinking]), routes unclosed thinking to `thinking` on
 * [finish], and passes non-thinking output straight through to `answer`.
 * Pure + deterministic → byte-identical twin of Swift `ThinkingSplitter`.
 */
class ThinkingSplitter(startsInsideThinking: Boolean = false) {
    data class Chunk(val thinking: String, val answer: String)

    private enum class State {
        AWAITING_OPEN,
        THINKING,
        ANSWER,
        FINISHED,
    }

    private var state: State = if (startsInsideThinking) State.THINKING else State.AWAITING_OPEN
    private var buffer: String = ""

    /** True while the splitter is currently inside a `<think>…</think>` block. */
    val isThinking: Boolean
        get() = state == State.THINKING

    /** Feed the next streamed text piece. Returns incremental `(thinking, answer)` deltas. */
    fun feed(piece: String): Chunk {
        if (piece.isEmpty()) return Chunk("", "")

        return when (state) {
            State.FINISHED -> Chunk("", "")
            State.ANSWER -> Chunk("", piece)
            State.THINKING -> {
                buffer += piece
                drainThinking()
            }
            State.AWAITING_OPEN -> {
                buffer += piece
                drainAwaitingOpen()
            }
        }
    }

    /**
     * Flush any held-back text at end of stream. Unclosed thinking flushes to `thinking` with
     * an empty `answer`; unconfirmed pre-open text (no `<think>` ever arrived) flushes to `answer`.
     */
    fun finish(): Chunk {
        val pending = buffer
        buffer = ""
        return when (state) {
            State.THINKING -> {
                state = State.FINISHED
                Chunk(pending, "")
            }
            State.AWAITING_OPEN -> {
                state = State.FINISHED
                Chunk("", pending)
            }
            State.ANSWER, State.FINISHED -> {
                state = State.FINISHED
                Chunk("", "")
            }
        }
    }

    private fun drainAwaitingOpen(): Chunk {
        var idx = 0
        while (idx < buffer.length && isAsciiWhitespace(buffer[idx])) {
            idx++
        }
        if (idx == buffer.length) {
            return Chunk("", "")
        }

        val remainder = buffer.substring(idx)
        if (remainder.startsWith(OPEN_TAG)) {
            buffer = remainder.substring(OPEN_TAG.length)
            state = State.THINKING
            return drainThinking()
        }

        if (OPEN_TAG.startsWith(remainder)) {
            return Chunk("", "")
        }

        val out = buffer
        buffer = ""
        state = State.ANSWER
        return Chunk("", out)
    }

    private fun drainThinking(): Chunk {
        val closeIdx = buffer.indexOf(CLOSE_TAG)
        if (closeIdx >= 0) {
            val thinkText = buffer.substring(0, closeIdx)
            val answerText = buffer.substring(closeIdx + CLOSE_TAG.length)
            buffer = ""
            state = State.ANSWER
            return Chunk(thinkText, answerText)
        }

        val holdLen = longestPrefixSuffixLength(buffer, CLOSE_TAG)
        val emitCount = buffer.length - holdLen
        if (emitCount <= 0) return Chunk("", "")

        val thinkText = buffer.substring(0, emitCount)
        buffer = buffer.substring(emitCount)
        return Chunk(thinkText, "")
    }

    companion object {
        private const val OPEN_TAG = "<think>"
        private const val CLOSE_TAG = "</think>"

        private fun isAsciiWhitespace(ch: Char): Boolean =
            ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'

        private fun longestPrefixSuffixLength(text: String, tag: String): Int {
            val maxLen = minOf(text.length, tag.length - 1)
            if (maxLen <= 0) return 0
            for (len in maxLen downTo 1) {
                if (text.regionMatches(text.length - len, tag, 0, len)) {
                    return len
                }
            }
            return 0
        }
    }
}
