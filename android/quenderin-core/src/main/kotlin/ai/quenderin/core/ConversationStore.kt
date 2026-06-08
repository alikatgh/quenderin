package ai.quenderin.core

/**
 * Persists a chat transcript so a conversation survives app relaunch — the offline-first
 * promise made concrete: history lives on-device, never on a server. Dependency-free
 * serialization to/from a String (the app writes it to a file, so the I/O stays at the
 * edge, the same shape as `DownloadStore`). One escaped `ROLE\ttext` row per turn, so text
 * containing newlines or tabs round-trips intact. Twin of Swift `ConversationStore`.
 */
class ConversationStore {

    /** Encode a transcript to a portable, dependency-free string. */
    fun encode(messages: List<ChatMessage>): String =
        messages.joinToString("\n") { "${it.role.name}\t${escape(it.text)}" }

    /** Decode a transcript; blank input is an empty conversation, not an error. */
    fun decode(text: String): List<ChatMessage> {
        if (text.isBlank()) return emptyList()
        return text.split("\n").mapNotNull { line ->
            val tab = line.indexOf('\t')
            if (tab < 0) return@mapNotNull null
            val role = runCatching { Role.valueOf(line.substring(0, tab)) }.getOrNull()
                ?: return@mapNotNull null
            ChatMessage(role, unescape(line.substring(tab + 1)))
        }
    }

    private fun escape(s: String): String =
        s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")

    private fun unescape(s: String): String = buildString {
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                when (s[i + 1]) {
                    'n' -> { append('\n'); i += 2 }
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
