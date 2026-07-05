package ai.quenderin.core

/**
 * Persists a chat transcript so a conversation survives app relaunch — the offline-first
 * promise made concrete: history lives on-device, never on a server. Dependency-free
 * serialization to/from a String (the app writes it to a file, so the I/O stays at the
 * edge, the same shape as `DownloadStore`). One escaped `ROLE\ttext` row per turn, so text
 * containing newlines or tabs round-trips intact. Twin of Swift `ConversationStore`.
 */
class ConversationStore {

    /** Encode a transcript to a portable, dependency-free string. Attached documents (Milestone 1)
     *  extend the row as `ROLE\ttext[\tname\ttext]...` — real tabs are escaped, so tab is a safe
     *  separator, and doc-free rows keep the original two-field shape (old files decode unchanged). */
    fun encode(messages: List<ChatMessage>): String =
        messages.joinToString("\n") { m ->
            val base = "${m.role.name}\t${escape(m.text)}"
            if (m.documents.isEmpty()) base
            else base + m.documents.joinToString("") { "\t${escape(it.name)}\t${escape(it.text)}" }
        }

    /** Decode a transcript; blank input is an empty conversation, not an error. */
    fun decode(text: String): List<ChatMessage> {
        if (text.isBlank()) return emptyList()
        return text.split("\n").mapNotNull { line ->
            val fields = line.split('\t')   // real tabs are escaped, so this splits FIELDS only
            if (fields.size < 2) return@mapNotNull null
            val role = runCatching { Role.valueOf(fields[0]) }.getOrNull()
                ?: return@mapNotNull null
            // Fields beyond the text come in (name, text) pairs; a dangling odd field means a torn
            // row — keep the message, drop the incomplete doc (same spirit as the ledger's torn tail).
            val docs = fields.drop(2).chunked(2)
                .filter { it.size == 2 }
                .map { AttachedDocument(unescape(it[0]), unescape(it[1])) }
            ChatMessage(role, unescape(fields[1]), docs)
        }
    }

    private fun escape(s: String): String =
        s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

    private fun unescape(s: String): String = buildString {
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                when (s[i + 1]) {
                    'n' -> { append('\n'); i += 2 }
                    'r' -> { append('\r'); i += 2 }
                    't' -> { append('\t'); i += 2 }
                    '\\' -> { append('\\'); i += 2 }
                    else -> { append(c); i++ }
                }
            } else {
                append(c); i++
            }
        }
    }
}
