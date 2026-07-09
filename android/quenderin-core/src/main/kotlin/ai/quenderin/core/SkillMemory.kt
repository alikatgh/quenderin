package ai.quenderin.core

/**
 * One proven skill: the ordered capability / tool names that got a past goal to an answer.
 * Twin of Swift `SkillRecord` and TS `SkillRecord`.
 */
data class SkillRecord(val goal: String, val tools: List<String>)

/**
 * Skill memory — the reliability-compounding loop for a weak local model (choosing the right
 * tool). After a task SUCCEEDS, record goal → tools that got there; prime the next SIMILAR goal
 * with that proven sequence. Pure policy, no Android framework — CoreVerify + the agent loop
 * both use this class.
 *
 * Byte-faithful twin of Swift `SkillMemory` and TS `src/services/capability/skillMemory.ts`:
 * ASCII `[a-z0-9]` tokens length > 2, overlap-coefficient similarity, same caps (goal 300,
 * tools 40, capacity 200, threshold 0.5).
 */
class SkillMemory(
    /** Below this goal-similarity a past skill isn't offered (avoid irrelevant priming). */
    private val threshold: Double = 0.5,
    /** Cap memory so it can't grow unbounded; oldest drop first. */
    private val capacity: Int = 200,
) {
    private val records = ArrayList<SkillRecord>()

    val size: Int get() = records.size

    /** Remember that [tools] accomplished [goal]. Ignores empty runs; de-dupes an identical goal. */
    fun record(goal: String, tools: List<String>) {
        val g = goal.trim().take(MAX_GOAL_LEN)
        if (g.isEmpty() || tools.isEmpty()) return
        records.removeAll { it.goal.equals(g, ignoreCase = true) }
        records.add(SkillRecord(g, tools.take(MAX_TOOLS)))
        while (records.size > capacity) records.removeAt(0)
    }

    /** The most similar past skills to [goal], best first (up to [k]), above the threshold. */
    fun recall(goal: String, k: Int = 2): List<SkillRecord> {
        val target = tokens(goal)
        return records
            .map { r -> r to similarity(target, tokens(r.goal)) }
            .filter { it.second >= threshold }
            .sortedByDescending { it.second }
            .take(k)
            .map { it.first }
    }

    /** Snapshot for persistence (the loop is only real if memory survives a restart). */
    fun snapshot(): List<SkillRecord> = records.map { SkillRecord(it.goal, it.tools.toList()) }

    /** Replace records from a persisted snapshot (validated + re-capped — untrusted file can't bloat). */
    fun restore(snapshot: List<SkillRecord>) {
        records.clear()
        for (r in snapshot) {
            if (r.goal.isEmpty() || r.tools.isEmpty()) continue
            records.add(SkillRecord(r.goal.take(MAX_GOAL_LEN), r.tools.take(MAX_TOOLS)))
            if (records.size >= capacity) break
        }
    }

    companion object {
        const val MAX_GOAL_LEN = 300
        const val MAX_TOOLS = 40

        /** Lowercase ASCII word tokens (length > 2), deduped — unit of goal similarity. */
        fun tokens(text: String): Set<String> {
            val out = LinkedHashSet<String>()
            val lower = text.lowercase()
            val sb = StringBuilder()
            fun flush() {
                if (sb.length > 2) out.add(sb.toString())
                sb.clear()
            }
            for (ch in lower) {
                if ((ch in 'a'..'z') || (ch in '0'..'9')) sb.append(ch) else flush()
            }
            flush()
            return out
        }

        /** Overlap coefficient: |A∩B| / min(|A|,|B|) — robust when goals differ in length. */
        fun similarity(a: Set<String>, b: Set<String>): Double {
            if (a.isEmpty() || b.isEmpty()) return 0.0
            var shared = 0
            for (t in a) if (t in b) shared++
            return shared.toDouble() / minOf(a.size, b.size).toDouble()
        }
    }
}

/**
 * Dependency-free wire format for [SkillMemory.snapshot] — one escaped row per record:
 *   `tool1,tool2\tgoal`
 * Same escape discipline as [AgentGoalHistory] (tabs/newlines/backslashes). The app edge
 * (SharedPreferences) owns WHERE the string lives; this object owns only the shape so CoreVerify
 * can round-trip without Android framework.
 */
object SkillMemoryCodec {
    fun encode(records: List<SkillRecord>): String =
        records.joinToString("\n") { r ->
            val tools = r.tools.joinToString(",") { escape(it) }
            "${tools}\t${escape(r.goal)}"
        }

    /** Decode; blank/corrupt input is empty — never throws. Torn rows are dropped. */
    fun decode(text: String): List<SkillRecord> {
        if (text.isBlank()) return emptyList()
        return text.split("\n").mapNotNull { line ->
            val fields = line.split('\t')
            if (fields.size != 2) return@mapNotNull null
            val tools = fields[0].split(',').map { unescape(it) }.filter { it.isNotEmpty() }
            val goal = unescape(fields[1])
            if (goal.isEmpty() || tools.isEmpty()) null else SkillRecord(goal, tools)
        }
    }

    private fun escape(s: String): String =
        s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace(",", "\\,")

    private fun unescape(s: String): String = buildString {
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                when (s[i + 1]) {
                    '\\' -> append('\\')
                    'n' -> append('\n')
                    'r' -> append('\r')
                    't' -> append('\t')
                    ',' -> append(',')
                    else -> { append(c); append(s[i + 1]) }
                }
                i += 2
            } else {
                append(c); i += 1
            }
        }
    }
}
