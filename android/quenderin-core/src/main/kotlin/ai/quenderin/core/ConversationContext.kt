package ai.quenderin.core

/**
 * Assembles the prompt sent to the engine from the running conversation: a system prompt
 * plus as much recent history as fits a token budget. This is what gives chat **memory** —
 * without it the model sees only the latest line and forgets every prior turn. Pure and
 * deterministic, so it unit-tests on the JVM with no engine. Twin of Swift
 * `ConversationContext`; mirrors the desktop's system-prompt + context-budget approach.
 */
class ConversationContext(
    /** Persona / standing instructions, always kept ahead of the history. */
    val systemPrompt: String = DEFAULT_SYSTEM_PROMPT,
    /** Approximate size of the model's context window, in tokens. */
    val contextTokens: Int = 4096,
    /** Tokens to leave free for the reply, so prompt + response fit the window. */
    val reservedForResponse: Int = 512,
) {
    /** Tokens available for history after the system prompt and the trailing primer, given the effective
     *  context window (defaults to the configured [contextTokens], but the loaded engine's real `n_ctx`
     *  is threaded in at runtime — see [windowedHistory]). */
    private fun historyBudget(effectiveContextTokens: Int): Int = maxOf(
        0,
        effectiveContextTokens - reservedForResponse -
            estimateTokens(systemPrompt) - estimateTokens(ASSISTANT_PRIMER),
    )

    /**
     * Build the instruct prompt, keeping the system prompt plus the most recent turns that
     * fit the budget (oldest dropped first; the latest turn is always kept, even if it alone
     * exceeds the budget — we never silently drop the message the user just sent).
     */
    /**
     * The most recent turns that fit the history budget (oldest dropped first; the latest turn is always
     * kept). This is the context-window trimming, WITHOUT the "User:/Assistant:" flattening — so a
     * chat-template-aware engine ([LlamaEngine]) can format the kept turns with the model's own template.
     *
     * [contextTokensOverride] is the loaded engine's ACTUAL `n_ctx` (often 512–2048 on phones, sized from
     * the device's memory at load) — when supplied it replaces the configured [contextTokens], so the trim
     * matches the real native window instead of a hardcoded 4096 that silently overflows it (Q-167). Null
     * (mock/scripted/off-device, and the pure prompt-building tests) falls back to [contextTokens].
     */
    fun windowedHistory(history: List<ChatMessage>, contextTokensOverride: Int? = null): List<ChatMessage> {
        val budget = historyBudget(contextTokensOverride ?: contextTokens)
        val kept = ArrayList<ChatMessage>()
        var used = 0
        for (message in history.asReversed()) {              // newest → oldest
            val cost = estimateTokens(line(message))
            if (kept.isEmpty() || used + cost <= budget) {
                kept += message
                used += cost
            } else {
                break
            }
        }
        kept.reverse()                                       // restore chronological order
        return kept
    }

    fun build(history: List<ChatMessage>): String {
        val kept = windowedHistory(history)
        return buildString {
            if (systemPrompt.isNotEmpty()) {
                append(systemPrompt)
                append("\n\n")
            }
            append(kept.joinToString("\n") { line(it) })
            if (kept.isNotEmpty()) append("\n")
            append(ASSISTANT_PRIMER)
        }
    }

    private fun line(m: ChatMessage): String =
        (if (m.role == Role.USER) "User: " else "Assistant: ") + m.text

    companion object {
        const val DEFAULT_SYSTEM_PROMPT =
            "You are Quenderin, a helpful assistant running entirely on-device and offline. " +
                "Be concise and accurate. You have no internet access."
        private const val ASSISTANT_PRIMER = "Assistant:"

        /**
         * Rough token estimate (~4 chars/token) — an honest stand-in until the real
         * llama.cpp tokenizer is wired; accurate enough for context-window budgeting.
         */
        fun estimateTokens(text: String): Int = maxOf(1, (text.length + 3) / 4)
    }
}
