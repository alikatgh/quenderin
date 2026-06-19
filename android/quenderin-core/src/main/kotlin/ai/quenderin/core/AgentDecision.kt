package ai.quenderin.core

/** One planner decision: call a tool, or give the final answer. Mirrors iOS `AgentDecision`. */
sealed interface AgentDecision {
    data class UseTool(val name: String, val input: String) : AgentDecision
    data class FinalAnswer(val answer: String) : AgentDecision
}

/**
 * Parse the planner's JSON, lenient to the prose local models love to wrap around it:
 *   {"tool":"calculator","input":"2+2"}   or   {"answer":"The result is 4."}
 * Dependency-free (no JSON library in the core) — extracts the known string keys directly.
 */
object AgentDecisionParser {
    fun parse(raw: String): AgentDecision? {
        val json = firstJsonObject(raw) ?: return null
        extractString(json, "answer")?.let { return AgentDecision.FinalAnswer(it) }
        val tool = extractString(json, "tool")
        if (!tool.isNullOrEmpty()) {
            return AgentDecision.UseTool(tool, extractString(json, "input") ?: "")
        }
        return null
    }

    /** The FIRST complete, balanced `{ ... }` object — walking braces (skipping quoted strings)
     *  instead of first-`{`..last-`}` so a second JSON object in the same response can't be merged
     *  in and return a premature/injected answer (H13; parity with Swift). */
    private fun firstJsonObject(text: String): String? {
        val start = text.indexOf('{')
        if (start < 0) return null
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while (i < text.length) {
            val c = text[i]
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
            } else {
                when (c) {
                    '"' -> inString = true
                    '{' -> depth++
                    '}' -> { depth--; if (depth == 0) return text.substring(start, i + 1) }
                }
            }
            i++
        }
        return null
    }

    private val ESCAPES = Regex("""\\(.)""")

    private fun extractString(json: String, key: String): String? {
        // "key" : "value-with-escapes"
        val m = Regex(""""$key"\s*:\s*"((?:[^"\\]|\\.)*)"""").find(json) ?: return null
        return ESCAPES.replace(m.groupValues[1]) { match ->
            when (match.groupValues[1]) {
                "n" -> "\n"
                "t" -> "\t"
                else -> match.groupValues[1] // \" -> ", \\ -> \, etc.
            }
        }
    }
}
