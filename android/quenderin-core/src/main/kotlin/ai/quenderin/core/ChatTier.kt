package ai.quenderin.core

/**
 * Size-class knobs for chat. Twin of iOS `ChatTier` — keep maxTokens / prompt suffixes aligned.
 */
enum class ChatTier {
    /** ~1–2B params — snappy, rambling risk high. */
    TINY,
    /** ~3–5B — default phone sweet spot. */
    SMALL,
    /** ~7B+ — more room for structured answers. */
    FULL;

    val maxTokens: Int
        get() = when (this) {
            TINY -> 256
            SMALL -> 384
            FULL -> 512
        }

    /** Extra system-prompt lines after [ConversationContext.DEFAULT_SYSTEM_PROMPT]. */
    val systemPromptSuffix: String
        get() = when (this) {
            TINY -> " Keep every reply under ~8 short sentences unless the user asks for more detail."
            SMALL -> " Prefer 1–3 short paragraphs or a tight bullet list."
            FULL -> ""
        }

    val systemPrompt: String
        get() = ConversationContext.DEFAULT_SYSTEM_PROMPT + systemPromptSuffix

    companion object {
        fun of(paramsBillions: Double): ChatTier = when {
            paramsBillions <= 2.0 -> TINY
            paramsBillions <= 5.5 -> SMALL
            else -> FULL
        }

        fun of(model: ModelEntry?): ChatTier =
            if (model == null) SMALL else of(model.paramsBillions)
    }
}
