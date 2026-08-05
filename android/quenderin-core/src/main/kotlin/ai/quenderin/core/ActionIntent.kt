package ai.quenderin.core

/**
 * Deterministic "this chat message is really a COMPUTER TASK" detector — twin of Swift
 * `ActionIntent` (identical pattern strings; both platforms run the same fixtures in their
 * checks). Detection in code lets the chat UI offer a one-tap "Open in Agent" handoff
 * instead of relying on the model to produce redirect prose the user must interpret.
 *
 * Conservative by design (precision over recall): a missed detection costs nothing — the chat
 * reply still explains — while a false positive nags.
 */
object ActionIntent {
    /** Regexes over the lowercased message. IDENTICAL strings in the Swift twin. */
    private val patterns: List<Regex> = listOf(
        """\b(open|launch|start|quit|close)\b.*\b(browser|safari|chrome|firefox|mail|finder|app|application)\b""",
        """\b(write|send|compose|draft)\b.*\b(e-?mail|message)\b""",
        """\b(organize|organise|clean|sort|tidy)\b.*\b(files?|folders?|desktop|downloads|documents)\b""",
        """\b(move|rename|trash|copy)\b.*\b(files?|folders?)\b""",
        """\brun\b.*\bshortcut""",
        """\b(create|make)\b.*\b(folder|directory)\b""",
    ).map { Regex(it) }

    /** True when the text reads as an operate-the-computer request rather than a question. */
    fun looksLikeComputerTask(text: String): Boolean {
        val lowered = text.lowercase()
        return patterns.any { it.containsMatchIn(lowered) }
    }

    /**
     * Fixed educational reply when chat short-circuits a computer task — no model call, no
     * "I cannot fulfill that request" wall. The UI always pairs this with a real button.
     * Mobile wording (phone), twin intent of iOS `guidedAssistantReply` (Mac).
     */
    const val GUIDED_ASSISTANT_REPLY =
        "Chat is for questions and writing help — it can’t open apps, control the browser, or send mail for you.\n\n" +
            "**The Agent can.** Tap **Agent** in the tab bar, or use the button below. " +
            "It will take your request and ask before changing anything."

    /** In-transcript / composer link label — modest, not a billboard. */
    const val HANDOFF_BUTTON_TITLE = "Open in Agent"

    /**
     * True when an assistant bubble is the old model-generated "use the Agent tab" wall — so the
     * UI can show [GUIDED_ASSISTANT_REPLY] instead of replaying "I cannot fulfill that request".
     */
    fun looksLikeAgentRedirectProse(text: String): Boolean {
        val t = text.lowercase()
        if (t.contains("i cannot fulfill")) return true
        if (t.contains("cannot open a browser") || t.contains("can't open a browser")) return true
        if (t.contains("agent tab") &&
            (t.contains("cannot") || t.contains("can't") ||
                t.contains("do not have the ability") || t.contains("don't have the ability") ||
                t.contains("designed to operate offline"))
        ) {
            return true
        }
        if (t.contains("sparkle") &&
            (t.contains("cannot") || t.contains("can't") || t.contains("please use the agent"))
        ) {
            return true
        }
        return false
    }

    /** Text to show for an assistant bubble: rewrite dead-end agent redirects to the guided copy. */
    fun displayAssistantText(text: String): String =
        if (looksLikeAgentRedirectProse(text)) GUIDED_ASSISTANT_REPLY else text
}
