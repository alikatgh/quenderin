package ai.quenderin.core

/**
 * Deterministic "this chat message is really a COMPUTER TASK" detector — twin of Swift
 * `ActionIntent` (identical pattern strings; both platforms run the same fixtures in their
 * checks). Detection in code lets the chat UI offer a one-tap "Run with the Agent" handoff
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
}
