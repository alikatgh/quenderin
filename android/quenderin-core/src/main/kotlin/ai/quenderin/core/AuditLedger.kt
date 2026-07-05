package ai.quenderin.core

import java.io.File

/**
 * One row of the agent's action ledger — what ran (or was refused), when, and what it touched.
 * The ledger is the user's flight recorder for autonomy (AGENT_AUTONOMY_PLAN §3.6): every
 * capability invocation is recorded, including the refused ones. Append-only by design.
 * Twin of iOS `AuditEntry`/`AuditLedger`.
 */
data class AuditEntry(
    val timestampMs: Long,
    val capability: String,
    val tier: Int,
    /** The input, truncated — the ledger explains actions; it is not a transcript store. */
    val input: String,
    /** "allowed" | "blocked(<keyword>)" | "needsConsent" | "error" */
    val decision: String,
    /** Truncated result/error when the capability actually ran; null when it was refused. */
    val outcome: String?,
) {
    companion object {
        fun of(timestampMs: Long, capability: String, tier: Int, input: String, decision: String, outcome: String?) =
            AuditEntry(timestampMs, capability, tier, input.take(200), decision, outcome?.take(200))
    }
}

/** Where audit entries go. */
interface AuditLedger {
    fun append(entry: AuditEntry)
    fun entries(): List<AuditEntry>
}

/** Test/default ledger — in memory, lock-protected. */
class InMemoryAuditLedger : AuditLedger {
    private val lock = Any()
    private val stored = mutableListOf<AuditEntry>()

    override fun append(entry: AuditEntry) = synchronized(lock) { stored.add(entry); Unit }
    override fun entries(): List<AuditEntry> = synchronized(lock) { stored.toList() }
}

/**
 * The real ledger: one JSON object per line (JSONL), appended to a file the user can open.
 * JSONL because append-only means a crash can at worst truncate the LAST line — every prior
 * action survives, and [entries] skips a torn tail instead of losing the whole log. Hand-rolled
 * JSON (the core is dependency-free), same shape as the iOS ledger.
 */
class FileAuditLedger(private val file: File) : AuditLedger {
    private val lock = Any()

    override fun append(entry: AuditEntry) {
        synchronized(lock) {
            try {
                file.parentFile?.mkdirs()
                file.appendText(encode(entry) + "\n")
            } catch (t: Throwable) {
                // The ledger must never take the agent down — but leave a trace (same rule as Q-009).
                System.err.println("[AuditLedger] append failed: ${t.message}")
            }
        }
    }

    override fun entries(): List<AuditEntry> = synchronized(lock) {
        if (!file.isFile) return emptyList()
        file.readLines().mapNotNull { decode(it) }
    }

    private fun esc(s: String) = s.replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

    private fun encode(e: AuditEntry): String = buildString {
        append("{\"timestampMs\":").append(e.timestampMs)
        append(",\"capability\":\"").append(esc(e.capability))
        append("\",\"tier\":").append(e.tier)
        append(",\"input\":\"").append(esc(e.input))
        append("\",\"decision\":\"").append(esc(e.decision)).append('"')
        e.outcome?.let { append(",\"outcome\":\"").append(esc(it)).append('"') }
        append('}')
    }

    // Minimal decoders for OUR OWN encoding above (fixed keys, known escapes) — a torn/corrupt
    // line yields null, not a crash. Deliberately not a general JSON parser.
    private fun long(line: String, key: String): Long? =
        Regex("\"$key\":(-?\\d+)").find(line)?.groupValues?.get(1)?.toLongOrNull()

    private fun str(line: String, key: String): String? {
        val marker = "\"$key\":\""
        var i = line.indexOf(marker)
        if (i < 0) return null
        i += marker.length
        val sb = StringBuilder()
        while (i < line.length) {
            when (val c = line[i]) {
                '"' -> return sb.toString()
                '\\' -> {
                    if (i + 1 >= line.length) return null   // torn mid-escape
                    when (val e = line[i + 1]) {
                        'n' -> sb.append('\n'); 'r' -> sb.append('\r'); 't' -> sb.append('\t')
                        else -> sb.append(e)                 // \" \\ and anything else literal
                    }
                    i++
                }
                else -> sb.append(c)
            }
            i++
        }
        return null   // no closing quote — torn line
    }

    private fun decode(line: String): AuditEntry? {
        return AuditEntry(
            timestampMs = long(line, "timestampMs") ?: return null,
            capability = str(line, "capability") ?: return null,
            tier = long(line, "tier")?.toInt() ?: return null,
            input = str(line, "input") ?: "",
            decision = str(line, "decision") ?: return null,
            outcome = str(line, "outcome"),
        )
    }
}
