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

        /**
         * Returns true when the chat prompt builder should close an empty `<think>` block after the
         * assistant turn: only when [mode] disallows thinking ([OFF]) AND the template supports it.
         * Twin of Swift `ThinkingMode.shouldCloseThinkBlock(mode:template:)`.
         */
        fun shouldCloseThinkBlock(mode: ThinkingMode, template: String): Boolean =
            !mode.allowsThinking && supports(template)

        private const val OPEN_TAG = "<think>"
        private const val CLOSE_TAG = "</think>"
        private val TURN_BOUNDARY_MARKERS = arrayOf(
            "<|im_start|>assistant",
            "<|im_end|>",
            "<|start_header_id|>assistant<|end_header_id|>",
            "<|eot_id|>",
            "<start_of_turn>model",
            "<start_of_turn>assistant",
            "<end_of_turn>",
            "<｜Assistant｜>",
            "<|Assistant|>",
            "<|assistant|>",
            "<|end|>",
            "[/INST]",
            "</s>",
            "\nAssistant:",
            "\nassistant:",
            "\rAssistant:",
            "\rassistant:",
        )
        private val LEADING_ASSISTANT_MARKERS = arrayOf(
            "Assistant:",
            "assistant:",
        )

        /**
         * Returns true when [text] contains a `<think>` tag not closed by a later `</think>`.
         * Twin of Swift `ThinkingMode.hasUnclosedThinkTag(in:)`.
         */
        fun hasUnclosedThinkTag(text: String): Boolean {
            val lastOpen = text.lastIndexOf(OPEN_TAG)
            if (lastOpen < 0) return false
            val lastClose = text.lastIndexOf(CLOSE_TAG)
            return lastClose < lastOpen
        }

        /**
         * Returns true when the current assistant generation prefix of [prompt] leaves an unclosed
         * `<think>` block — including prefixes with text after `<think>` (e.g. `<think>\nReasoning: `)
         * — while ignoring literal `<think>` tags inside earlier user/system messages.
         * When [withoutAssistantPrefix] (the template rendered with `add_ass = false`) is a prefix
         * of [prompt], only the exact assistant-prefix suffix is inspected.
         * Twin of Swift `ThinkingMode.promptEndsInsideThinking(_:withoutAssistantPrefix:)`.
         */
        fun promptEndsInsideThinking(prompt: String, withoutAssistantPrefix: String): Boolean {
            if (withoutAssistantPrefix.isNotEmpty() && prompt.startsWith(withoutAssistantPrefix)) {
                return hasUnclosedThinkTag(prompt.substring(withoutAssistantPrefix.length))
            }
            return promptEndsInsideThinking(prompt)
        }

        /**
         * Returns true when a rendered chat prompt's current assistant prefix leaves an unclosed
         * `<think>` block (even if non-empty text such as `Reasoning: ` follows `<think>`), while
         * ignoring literal `<think>` tags in earlier user messages.
         * Twin of Swift `ThinkingMode.promptEndsInsideThinking(_:)`.
         */
        fun promptEndsInsideThinking(prompt: String): Boolean {
            if (prompt.isEmpty()) return false
            var boundaryEnd = -1
            for (marker in TURN_BOUNDARY_MARKERS) {
                val idx = prompt.lastIndexOf(marker)
                if (idx >= 0) {
                    val end = idx + marker.length
                    if (end > boundaryEnd) boundaryEnd = end
                }
            }
            for (leading in LEADING_ASSISTANT_MARKERS) {
                if (prompt.startsWith(leading) && leading.length > boundaryEnd) {
                    boundaryEnd = leading.length
                }
            }
            if (boundaryEnd >= 0) {
                return hasUnclosedThinkTag(prompt.substring(boundaryEnd))
            }

            var start = 0
            while (start < prompt.length) {
                val ch = prompt[start]
                if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
                    start++
                } else {
                    break
                }
            }
            val trimmed = prompt.substring(start)
            return trimmed.startsWith(OPEN_TAG) && hasUnclosedThinkTag(trimmed)
        }
    }
}

/**
 * Streaming splitter that separates `<think>…</think>` reasoning from the visible answer across
 * arbitrary token boundaries. Holds back only a possible partial tag suffix (like
 * `StopSequenceScanner`), holds leading ASCII whitespace at stream start until the first
 * non-whitespace char (dropping it if `<think>` immediately follows, or preserving it in `answer`
 * otherwise), routes every `<think>…</think>` block anywhere in the stream (even after a preamble
 * or across multiple blocks) into `thinking`, supports pre-opened templates
 * ([startsInsideThinking]), and routes unclosed thinking to `thinking` on [finish].
 * Pure + deterministic → byte-identical twin of Swift `ThinkingSplitter`.
 */
class ThinkingSplitter(startsInsideThinking: Boolean = false) {
    data class Chunk(val thinking: String, val answer: String)

    private enum class State {
        AWAITING_INITIAL_OPEN,
        OUTSIDE,
        THINKING,
        FINISHED,
    }

    private var state: State = if (startsInsideThinking) State.THINKING else State.AWAITING_INITIAL_OPEN
    private var buffer: String = ""

    /** True while the splitter is currently inside a `<think>…</think>` block. */
    val isThinking: Boolean
        get() = state == State.THINKING

    /** Feed the next streamed text piece. Returns incremental `(thinking, answer)` deltas. */
    fun feed(piece: String): Chunk {
        if (piece.isEmpty() || state == State.FINISHED) return Chunk("", "")
        buffer += piece
        return drain()
    }

    /**
     * Flush any held-back text at end of stream. Unclosed thinking flushes to `thinking` with
     * an empty `answer`; unconfirmed pre-open or trailing partial open-tag text flushes to `answer`.
     */
    fun finish(): Chunk {
        val pending = buffer
        buffer = ""
        return when (state) {
            State.THINKING -> {
                state = State.FINISHED
                Chunk(pending, "")
            }
            State.AWAITING_INITIAL_OPEN, State.OUTSIDE -> {
                state = State.FINISHED
                Chunk("", pending)
            }
            State.FINISHED -> Chunk("", "")
        }
    }

    private fun drain(): Chunk {
        val thinkingOut = StringBuilder()
        val answerOut = StringBuilder()

        loop@ while (buffer.isNotEmpty()) {
            when (state) {
                State.FINISHED -> break@loop

                State.AWAITING_INITIAL_OPEN -> {
                    var idx = 0
                    while (idx < buffer.length && isAsciiWhitespace(buffer[idx])) {
                        idx++
                    }
                    if (idx == buffer.length) {
                        break@loop
                    }

                    val remainder = buffer.substring(idx)
                    if (remainder.startsWith(OPEN_TAG)) {
                        buffer = remainder.substring(OPEN_TAG.length)
                        state = State.THINKING
                        continue@loop
                    }
                    if (OPEN_TAG.startsWith(remainder)) {
                        break@loop
                    }

                    state = State.OUTSIDE
                    continue@loop
                }

                State.OUTSIDE -> {
                    val openIdx = buffer.indexOf(OPEN_TAG)
                    if (openIdx >= 0) {
                        if (openIdx > 0) answerOut.append(buffer, 0, openIdx)
                        buffer = buffer.substring(openIdx + OPEN_TAG.length)
                        state = State.THINKING
                        continue@loop
                    }

                    val holdLen = longestPrefixSuffixLength(buffer, OPEN_TAG)
                    val emitCount = buffer.length - holdLen
                    if (emitCount > 0) {
                        answerOut.append(buffer, 0, emitCount)
                        buffer = buffer.substring(emitCount)
                    }
                    break@loop
                }

                State.THINKING -> {
                    val closeIdx = buffer.indexOf(CLOSE_TAG)
                    if (closeIdx >= 0) {
                        if (closeIdx > 0) thinkingOut.append(buffer, 0, closeIdx)
                        buffer = buffer.substring(closeIdx + CLOSE_TAG.length)
                        state = State.OUTSIDE
                        continue@loop
                    }

                    val holdLen = longestPrefixSuffixLength(buffer, CLOSE_TAG)
                    val emitCount = buffer.length - holdLen
                    if (emitCount > 0) {
                        thinkingOut.append(buffer, 0, emitCount)
                        buffer = buffer.substring(emitCount)
                    }
                    break@loop
                }
            }
        }

        return Chunk(thinkingOut.toString(), answerOut.toString())
    }

    companion object {
        private const val OPEN_TAG = "<think>"
        private const val CLOSE_TAG = "</think>"

        /**
         * Initializes a splitter from the rendered prompt sent to the model: an unclosed trailing
         * `<think>` starts inside the thinking state so pre-opened templates never leak reasoning
         * into the visible answer. Twin of Swift `ThinkingSplitter(renderedPrompt:)`.
         */
        fun forRenderedPrompt(prompt: String): ThinkingSplitter =
            ThinkingSplitter(startsInsideThinking = ThinkingMode.promptEndsInsideThinking(prompt))

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
