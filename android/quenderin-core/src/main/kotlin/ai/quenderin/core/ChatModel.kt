package ai.quenderin.core

enum class Role { USER, ASSISTANT }

data class ChatMessage(val role: Role, val text: String)

/**
 * M2 chat brain: holds the transcript, sends a prompt to the [engine], appends the
 * reply. Dependency-free and listener-based ([onChange]) so it unit-tests on the JVM;
 * the Compose layer maps [onChange] into state and runs [send] off the main thread
 * (optionally via [LlamaEngine.complete]'s streaming overload for token-by-token UI).
 * Twin of Swift `ChatModel`.
 */
class ChatModel(
    private val engine: InferenceEngine,
    var onChange: (List<ChatMessage>) -> Unit = {},
) {
    private val _messages = mutableListOf<ChatMessage>()
    val messages: List<ChatMessage> get() = _messages.toList()

    private fun emit() = onChange(messages)

    /**
     * Appends the user's line, runs the engine over the whole transcript, appends the
     * assistant reply, and returns it. Throws [EngineNotLoadedException] if no model is
     * loaded (surfaced to the UI, never swallowed).
     */
    fun send(text: String): String {
        val trimmed = text.trim()
        require(trimmed.isNotEmpty()) { "Message is empty" }
        _messages += ChatMessage(Role.USER, trimmed)
        emit()
        val reply = engine.complete(buildPrompt())
        _messages += ChatMessage(Role.ASSISTANT, reply)
        emit()
        return reply
    }

    /** Render the transcript into a simple instruct-style prompt for the engine. */
    private fun buildPrompt(): String = buildString {
        for (m in _messages) {
            append(if (m.role == Role.USER) "User: " else "Assistant: ")
            append(m.text)
            append('\n')
        }
        append("Assistant: ")
    }

    fun reset() {
        _messages.clear()
        emit()
    }
}
