import Foundation
import Combine

public struct ChatMessage: Sendable, Identifiable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public extension ChatMessage {
    /// True when this is an assistant message whose text trips `SafetyBlocklist` — the chat UI
    /// surfaces a non-blocking warning (`SupportContact.flaggedOutputNotice`) rather than
    /// suppressing it, the on-device "minimize risk" safeguard for the Generative-AI policies.
    /// User messages are never flagged. Kept in parity with Android `ChatMessage.isFlagged`.
    var isFlagged: Bool { role == .assistant && SafetyBlocklist.isBlocked(text) }
}

/// Drives a chat conversation against any `InferenceEngine`, appending tokens to
/// the in-flight assistant message as they stream in. Runs on the mock engine
/// today; swaps to `LlamaEngine` with no change.
@MainActor
public final class ChatModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isGenerating = false

    private let engine: InferenceEngine
    private let context: ConversationContext

    public init(engine: InferenceEngine, context: ConversationContext = .init()) {
        self.engine = engine
        self.context = context
    }

    /// Send a prompt and stream the reply. No-ops on empty input or while a
    /// previous generation is still running.
    public func send(_ prompt: String, options: GenerationOptions = .init()) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        // Build the prompt from the whole conversation (system prompt + history within the
        // context-window budget) so the assistant remembers prior turns — not just this line.
        let enginePrompt = context.build(history: messages)
        var assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let index = messages.count - 1

        isGenerating = true
        defer { isGenerating = false }

        do {
            let stream = try await engine.generate(prompt: enginePrompt, options: options)
            for try await token in stream {
                assistant.text += token
                messages[index] = assistant
            }
        } catch {
            assistant.text = "⚠️ " + OnboardingModel.describe(error)
            messages[index] = assistant
        }
    }

    /// Clear the conversation.
    public func reset() {
        messages.removeAll()
    }

    /// Replace the transcript with a previously persisted conversation (see `ConversationStore`),
    /// so a chat picks up exactly where it left off after a relaunch.
    public func restore(_ saved: [ChatMessage]) {
        messages = saved
    }
}
