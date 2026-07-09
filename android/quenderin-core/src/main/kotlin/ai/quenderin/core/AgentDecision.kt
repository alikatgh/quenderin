package ai.quenderin.core

/** One step of a proposed multi-step plan. Mirrors iOS `ToolCall`. */
data class ToolCall(val name: String, val input: String)

/** One planner decision: call a tool, propose a plan, or give the final answer. Mirrors iOS. */
sealed interface AgentDecision {
    data class UseTool(val name: String, val input: String) : AgentDecision
    /** Several tool calls proposed AS ONE UNIT — approved by the user once (Milestone 3).
     *  Never empty (the parser rejects an empty plan). */
    data class Plan(val calls: List<ToolCall>) : AgentDecision
    data class FinalAnswer(val answer: String) : AgentDecision
}

/**
 * Parse the planner's JSON, lenient to the prose local models love to wrap around it:
 *   {"tool":"calculator","input":"2+2"}   or   {"answer":"The result is 4."}
 * Dependency-free (no JSON library in the core) — extracts the known string keys directly.
 */
object AgentDecisionParser {
    /**
     * Model copied a prompt template (`{"tool":"<name>","input":"<text>"}`) instead of a real id.
     * Twin of Swift `AgentDecisionParser.isPlaceholderToolName` — treat as parse failure.
     */
    fun isPlaceholderToolName(name: String): Boolean {
        val t = name.trim().lowercase()
        if (t.isEmpty()) return true
        if (t.startsWith("<") && t.endsWith(">")) return true
        if (t.contains('<') || t.contains('>')) return true
        return t in setOf(
            "name", "tool", "text", "input", "tool_name", "toolname",
            "<name>", "<tool>", "<text>", "<input>",
        )
    }

    fun parse(raw: String): AgentDecision? {
        val json = firstJsonObject(raw) ?: return null
        // Precedence when several keys appear: answer > plan > tool — identical on iOS.
        extractString(json, "answer")?.let { return AgentDecision.FinalAnswer(it) }
        extractArray(json, "plan")?.let { arrayBody ->
            // STRICT and AUTHORITATIVE: a top-level "plan" array is THE decision — any non-object
            // member, torn object, missing/empty "tool", or empty array is a parse failure (null),
            // NEVER a fall-through to the top-level "tool" key. splitObjects used to silently drop
            // non-object members ("garbage" strings) so the size guard passed over the survivors and
            // a garbled plan half-executed here while iOS ran the bare tool — same model output, two
            // different tool executions (twin-drift audit, agent-loop P1/P2; both parsers now agree).
            val objects = splitObjects(arrayBody) ?: return null
            val calls = objects.map { obj ->
                val tool = extractString(obj, "tool")
                if (tool.isNullOrEmpty() || isPlaceholderToolName(tool)) return null
                ToolCall(tool, extractString(obj, "input") ?: "")
            }
            return if (calls.isNotEmpty()) AgentDecision.Plan(calls) else null
        }
        val tool = extractString(json, "tool")
        if (!tool.isNullOrEmpty()) {
            if (isPlaceholderToolName(tool)) return null
            return AgentDecision.UseTool(tool, extractString(json, "input") ?: "")
        }
        return null
    }

    /** The raw `[ ... ]` body of a DEPTH-1 array member `"key": [ ... ]` — same top-level-only
     *  discipline as [extractString], so a nested "plan" scratch field is invisible. */
    private fun extractArray(json: String, key: String): String? {
        val quotedKey = "\"$key\""
        var depth = 0
        var inString = false
        var escaped = false
        var i = 0
        while (i < json.length) {
            val c = json[i]
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
                i++
                continue
            }
            when (c) {
                '"' -> {
                    if (depth == 1 && json.startsWith(quotedKey, i)) {
                        var j = i + quotedKey.length
                        while (j < json.length && json[j].isWhitespace()) j++
                        if (j < json.length && json[j] == ':') {
                            j++
                            while (j < json.length && json[j].isWhitespace()) j++
                            if (j < json.length && json[j] == '[') {
                                // Capture the balanced [ ... ] (skipping strings), exclusive of brackets.
                                var bracketDepth = 0
                                var inner = false
                                var esc = false
                                var k = j
                                while (k < json.length) {
                                    val ch = json[k]
                                    if (inner) {
                                        when {
                                            esc -> esc = false
                                            ch == '\\' -> esc = true
                                            ch == '"' -> inner = false
                                        }
                                    } else when (ch) {
                                        '"' -> inner = true
                                        '[' -> bracketDepth++
                                        ']' -> { bracketDepth--; if (bracketDepth == 0) return json.substring(j + 1, k) }
                                    }
                                    k++
                                }
                                return null   // unbalanced — torn output
                            }
                        }
                    }
                    inString = true
                }
                '{', '[' -> depth++
                '}', ']' -> depth--
            }
            i++
        }
        return null
    }

    /** Split an array body into its balanced top-level `{ ... }` objects (strings skipped inside
     *  them). Returns null when ANY top-level member is not an object — a "garbage" string, number,
     *  nested array, or torn brace — so a mixed plan is a whole-plan failure, never a silent
     *  partial (parity with iOS, whose all-or-nothing member check nils the same inputs). */
    private fun splitObjects(body: String): List<String>? {
        val objects = mutableListOf<String>()
        var i = 0
        while (i < body.length) {
            val c = body[i]
            when {
                c.isWhitespace() || c == ',' -> i++
                c == '{' -> {
                    val obj = firstJsonObject(body.substring(i)) ?: return null   // torn output
                    objects.add(obj)
                    i += obj.length
                }
                else -> return null   // non-object member — the whole plan is invalid
            }
        }
        return objects
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

    /**
     * "key" : "value-with-escapes" — but ONLY at depth 1 (i.e. a direct top-level member of the
     * outer `{...}` passed in), never inside a nested object/array value. The old flat regex scanned
     * the whole string regardless of nesting, so a key buried inside a nested object/array (e.g. a
     * "reasoning": {...} scratch field) was indistinguishable from the real top-level key — Android
     * could pick a totally different decision than iOS's JSONSerialization, which only ever reads
     * top-level keys (parity break). Track depth the same way firstJsonObject does; only test a
     * `"key":` match when depth == 1 right after the opening `{`.
     */
    private fun extractString(json: String, key: String): String? {
        val quotedKey = "\"$key\""
        var depth = 0
        var inString = false
        var escaped = false
        var i = 0
        while (i < json.length) {
            val c = json[i]
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
                i++
                continue
            }
            when (c) {
                '"' -> {
                    inString = true
                    if (depth == 1 && json.startsWith(quotedKey, i)) {
                        var j = i + quotedKey.length
                        while (j < json.length && json[j].isWhitespace()) j++
                        if (j < json.length && json[j] == ':') {
                            j++
                            while (j < json.length && json[j].isWhitespace()) j++
                            if (j < json.length && json[j] == '"') {
                                val m = Regex(""""((?:[^"\\]|\\.)*)"""").find(json, j) ?: return null
                                return unescapeJsonString(m.groupValues[1])
                            }
                        }
                    }
                }
                '{', '[' -> depth++
                '}', ']' -> depth--
            }
            i++
        }
        return null
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
