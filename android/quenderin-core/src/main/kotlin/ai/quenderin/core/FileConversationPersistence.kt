package ai.quenderin.core

import java.io.File

/**
 * File-backed [ConversationPersistence]: each transcript is a [ConversationStore] string, plus a
 * small index file of escaped `id \t title \t updatedAt` rows, under a directory the app owns (the
 * app passes `File(filesDir, "conversations")`). Dependency-free `java.io` so it runs in the
 * headless core verification. Twin of Swift `FileConversationPersistence`.
 */
class FileConversationPersistence(private val dir: File) : ConversationPersistence {
    private val store = ConversationStore()

    init { dir.mkdirs() }

    // ids are UUID strings (no separators); use just the file name as a defensive guard so a
    // hostile id can never escape the directory.
    private fun transcriptFile(id: String) = File(dir, File(id).name + ".txt")
    private val indexFile get() = File(dir, "index.tsv")

    override fun saveTranscript(id: String, messages: List<ChatMessage>) {
        runCatching { transcriptFile(id).writeText(store.encode(messages)) }
    }

    override fun loadTranscript(id: String): List<ChatMessage> {
        val file = transcriptFile(id)
        if (!file.exists()) return emptyList()   // missing == empty conversation, not an error
        return runCatching { store.decode(file.readText()) }.getOrDefault(emptyList())
    }

    override fun deleteTranscript(id: String) {
        runCatching { transcriptFile(id).delete() }
    }

    override fun saveIndex(summaries: List<ConversationSummary>) {
        val text = summaries.joinToString("\n") { "${it.id}\t${escape(it.title)}\t${it.updatedAt}" }
        runCatching { indexFile.writeText(text) }
    }

    override fun loadIndex(): List<ConversationSummary> {
        if (!indexFile.exists()) return emptyList()
        val text = runCatching { indexFile.readText() }.getOrDefault("")
        if (text.isBlank()) return emptyList()
        return text.split("\n").mapNotNull { line ->
            val parts = line.split("\t")
            if (parts.size < 3) return@mapNotNull null
            val updatedAt = parts[2].toLongOrNull() ?: return@mapNotNull null
            ConversationSummary(parts[0], unescape(parts[1]), updatedAt)
        }
    }

    // The title can in principle contain a tab/newline; escape so a row can't be split wrong.
    private fun escape(s: String) = s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
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
