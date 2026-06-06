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

/// Drives a chat conversation against any `InferenceEngine`, appending tokens to
/// the in-flight assistant message as they stream in. Runs on the mock engine
/// today; swaps to `LlamaEngine` with no change.
@MainActor
public final class ChatModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isGenerating = false

    private let engine: InferenceEngine

    public init(engine: InferenceEngine) {
        self.engine = engine
    }

    /// Send a prompt and stream the reply. No-ops on empty input or while a
    /// previous generation is still running.
    public func send(_ prompt: String, options: GenerationOptions = .init()) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        var assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let index = messages.count - 1

        isGenerating = true
        defer { isGenerating = false }

        do {
            let stream = try await engine.generate(prompt: trimmed, options: options)
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
}
