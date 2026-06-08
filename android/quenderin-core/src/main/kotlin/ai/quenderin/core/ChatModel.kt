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
    private val context: ConversationContext = ConversationContext(),
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
        // Prompt = system prompt + prior history within the context-window budget, so the
        // assistant remembers earlier turns (not just this line).
        val reply = engine.complete(context.build(_messages))
        _messages += ChatMessage(Role.ASSISTANT, reply)
        emit()
        return reply
    }

    fun reset() {
        _messages.clear()
        emit()
    }

    /** Replace the transcript with a previously persisted conversation (see [ConversationStore]),
     *  so a chat picks up exactly where it left off after a relaunch. */
    fun restore(saved: List<ChatMessage>) {
        _messages.clear()
        _messages.addAll(saved)
        emit()
    }
}
