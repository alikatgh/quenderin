package ai.quenderin.core

/**
 * Renders a chat transcript to a portable Markdown document the user can share or save — their data
 * stays theirs, exportable off the device on THEIR terms (not silently uploaded). Pure + testable.
 * Twin of Swift `ConversationExporter`.
 */
object ConversationExporter {
    fun markdown(messages: List<ChatMessage>, title: String? = null): String {
        val heading = title?.trim().takeUnless { it.isNullOrEmpty() } ?: "Conversation"
        val count = messages.size
        val sb = StringBuilder()
        sb.append("# ").append(heading).append("\n\n")
        sb.append("_Exported from Quenderin — on-device, ").append(count)
            .append(" message").append(if (count == 1) "" else "s").append("._\n\n")
        for (m in messages) {
            val speaker = if (m.role == Role.USER) "You" else "Quenderin"
            sb.append("**").append(speaker).append(":**\n").append(m.text).append("\n\n")
        }
        return sb.toString().trim() + "\n"
    }
}
