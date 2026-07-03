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

    /// Set by `stopGenerating()`; checked per token so a stop lands within one token.
    private var stopRequested = false

    /// Stop the current reply where it is — the streamed partial stays in the transcript
    /// (stopping is a decision about YOUR time, not a failure; no error styling).
    public func stopGenerating() {
        stopRequested = true
    }

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
        // Chat-structured generation: pass the budget-windowed history so the engine formats it
        // with the model's OWN chat template (answers as an assistant, stops at end-of-turn).
        // Template-less engines fall back to the flat transcript; the assistant remembers prior
        // turns either way.
        let windowed = context.windowedHistory(messages)
        var assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let assistantID = assistant.id   // track by id, NOT a captured index — `messages` can be mutated

        isGenerating = true
        stopRequested = false
        defer { isGenerating = false }

        do {
            let stream = try await engine.generateChat(system: context.systemPrompt, history: windowed, options: options)
            for try await token in stream {
                // Dropping the iterator on break terminates the stream (the engine's
                // onTermination stops decoding), so Stop also stops the compute.
                if stopRequested { break }
                assistant.text += token
                // `send` is @MainActor, but every `await` above yields the actor — so `reset()`
                // (clear) or `restore()` (open history) can mutate `messages` mid-stream. Look the
                // message up by id each token: a captured index would crash (out of range) or write
                // to the wrong message. If it's gone, the user moved on — stop streaming into it.
                guard let i = messages.firstIndex(where: { $0.id == assistantID }) else { return }
                messages[i] = assistant
            }
        } catch {
            assistant.text = "⚠️ " + OnboardingModel.describe(error)
            if let i = messages.firstIndex(where: { $0.id == assistantID }) { messages[i] = assistant }
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
