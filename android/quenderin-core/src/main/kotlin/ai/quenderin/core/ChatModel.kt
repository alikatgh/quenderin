package ai.quenderin.core

enum class Role { USER, ASSISTANT }

data class ChatMessage(val role: Role, val text: String)

/**
 * True when this is an assistant message whose text trips [SafetyBlocklist] — the chat UI surfaces
 * a non-blocking warning ([SupportContact.FLAGGED_OUTPUT_NOTICE]) rather than suppressing it, the
 * on-device "minimize risk" safeguard for the Generative-AI policies. User messages are never
 * flagged. Kept in parity with iOS `ChatMessage.isFlagged`.
 */
val ChatMessage.isFlagged: Boolean
    get() = role == Role.ASSISTANT && SafetyBlocklist.isBlocked(text)

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
        // Prompt = system prompt + prior history within the context-window budget, so the assistant
        // remembers earlier turns (not just this line). Build it BEFORE the placeholder is appended.
        val prompt = context.build(_messages)

        // Stream the reply into a placeholder assistant message so it appears token-by-token instead of
        // the UI sitting blank for the whole (multi-second) generation — the difference between the user
        // seeing "it's typing…" vs. concluding "it's not answering at all". Mirrors iOS `ChatModel`.
        val placeholderIndex = _messages.size
        _messages += ChatMessage(Role.ASSISTANT, "")
        emit()
        val sb = StringBuilder()
        val reply = engine.complete(prompt) { piece ->
            sb.append(piece)
            _messages[placeholderIndex] = ChatMessage(Role.ASSISTANT, sb.toString())
            emit()
        }
        // Settle on the authoritative full text (covers the non-streaming fallback, where onToken never
        // fired and the placeholder is still empty).
        _messages[placeholderIndex] = ChatMessage(Role.ASSISTANT, reply)
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
