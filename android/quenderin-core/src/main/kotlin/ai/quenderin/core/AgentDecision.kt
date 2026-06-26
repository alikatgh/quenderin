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

    private fun extractString(json: String, key: String): String? {
        // "key" : "value-with-escapes"
        val m = Regex(""""$key"\s*:\s*"((?:[^"\\]|\\.)*)"""").find(json) ?: return null
        return unescapeJsonString(m.groupValues[1])
    }

    /**
     * Decode a JSON string body's escapes to match iOS's `JSONSerialization`: the short escapes
     * (`\n \t \r \b \f \" \\ \/`) AND `\uXXXX` (surrogate pairs fall out for free — each `\u` maps to
     * one UTF-16 char). Without the `\u` case the old one-char unescaper rendered a model that escapes
     * non-ASCII (`café`) as `cafu00e9` on Android ONLY — a cross-platform parity bug in agent
     * answers (docs/BUG_JOURNAL.md). Lenient on a malformed escape: keep the char (prior behaviour).
     */
    private fun unescapeJsonString(s: String): String {
        if (s.indexOf('\\') < 0) return s   // fast path: nothing to decode
        val sb = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c != '\\' || i + 1 >= s.length) { sb.append(c); i++; continue }
            when (val n = s[i + 1]) {
                'n' -> { sb.append('\n'); i += 2 }
                't' -> { sb.append('\t'); i += 2 }
                'r' -> { sb.append('\r'); i += 2 }
                'b' -> { sb.append('\b'); i += 2 }
                'f' -> { sb.append('\u000C'); i += 2 }
                '"' -> { sb.append('"'); i += 2 }
                '\\' -> { sb.append('\\'); i += 2 }
                '/' -> { sb.append('/'); i += 2 }
                'u' -> {
                    val code = if (i + 6 <= s.length) s.substring(i + 2, i + 6).toIntOrNull(16) else null
                    if (code != null) { sb.append(code.toChar()); i += 6 }
                    else { sb.append(n); i += 2 }   // malformed \u — drop the backslash, keep 'u'
                }
                else -> { sb.append(n); i += 2 }   // unknown escape — keep the char (prior leniency)
            }
        }
        return sb.toString()
    }
}
