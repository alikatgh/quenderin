import Foundation
import Combine

/// A document the user attached to a chat message — name for display, extracted text for the
/// model. Extraction happens AT ATTACH TIME (strict UTF-8, size-capped) so what the model sees
/// is fixed when the message is sent, even if the file changes later. Twin of Kotlin
/// `AttachedDocument` (Milestone 1, roadmap Stage 2 "documents in chat").
public struct AttachedDocument: Sendable, Equatable, Codable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public struct ChatMessage: Sendable, Identifiable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    /// Documents attached to this (user) message. The transcript shows chips + the typed text;
    /// `engineText` is what the model gets.
    public var documents: [AttachedDocument]

    public init(id: UUID = UUID(), role: Role, text: String, documents: [AttachedDocument] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.documents = documents
    }

    /// The text the ENGINE sees: attached documents first (clearly labeled), then the typed
    /// message. Kept out of `text` so bubbles/persistence previews stay readable, but composed
    /// into every windowed history pass — follow-up questions still have the document in context.
    public var engineText: String {
        guard !documents.isEmpty else { return text }
        let docs = documents.map { "Attached file \"\($0.name)\":\n\($0.text)" }.joined(separator: "\n\n")
        return "\(docs)\n\n\(text)"
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
    /// True when the last settled reply stopped because it hit `options.maxTokens` (not Stop, not
    /// EOG). The chat UI surfaces a "Continue" chip so a mid-sentence cut is recoverable
    /// (KNOWN_FAILURE_MODES). Cleared on the next send / reset / restore.
    @Published public private(set) var lastHitTokenCap = false

    /// Set by `stopGenerating()`; checked per token so a stop lands within one token.
    private var stopRequested = false

    /// Stop the current reply where it is — the streamed partial stays in the transcript
    /// (stopping is a decision about YOUR time, not a failure; no error styling).
    public func stopGenerating() {
        stopRequested = true
        // The token loop below only lands a stop AT a token boundary, and never during prefill
        // (before the first token) — so also tell the engine to interrupt its native decode now,
        // ending generation in <500ms even mid-prefill (Q-005/Q-217).
        engine.requestCancel()
    }

    /// Extend the previous reply after a token-cap stop. Sends a short continue cue so the model
    /// picks up mid-thought. No-op when `lastHitTokenCap` is false.
    public func continueLast(options: GenerationOptions = .init()) async {
        guard lastHitTokenCap, !isGenerating else { return }
        await send("Continue from where you left off. Do not repeat what you already wrote.", options: options)
    }

    private let engine: InferenceEngine
    private let context: ConversationContext

    public init(engine: InferenceEngine, context: ConversationContext = .init()) {
        self.engine = engine
        self.context = context
    }

    /// Send a prompt and stream the reply. No-ops on empty input (unless documents are
    /// attached — "summarize this file" with no extra words is a legitimate send) or while a
    /// previous generation is still running.
    public func send(_ prompt: String, documents: [AttachedDocument] = [], options: GenerationOptions = .init()) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !documents.isEmpty, !isGenerating else { return }

        isGenerating = true
        stopRequested = false
        lastHitTokenCap = false
        defer { isGenerating = false }

        // The engine's REAL loaded `n_ctx` (often 512–2048 on phones), so the history trim below
        // matches the actual native window instead of the configured 4096 (Q-167 — Android had this,
        // iOS didn't; twin-drift audit). Awaited BEFORE any transcript mutation and only AFTER
        // `isGenerating` is set: every await yields the main actor, and a reentrant send must not
        // slip past the guard (the @MainActor+await journal pattern).
        let realContextTokens = await engine.loadedContextTokens()

        messages.append(ChatMessage(role: .user, text: trimmed, documents: documents))
        // Chat-structured generation: pass the budget-windowed history so the engine formats it
        // with the model's OWN chat template (answers as an assistant, stops at end-of-turn).
        // Template-less engines fall back to the flat transcript; the assistant remembers prior
        // turns either way. Attached documents are composed in (engineText) BEFORE windowing so
        // the token budget counts them.
        let windowed = context.windowedHistory(messages.map { message in
            guard !message.documents.isEmpty else { return message }
            var composed = message
            composed.text = message.engineText
            composed.documents = []
            return composed
        }, contextTokensOverride: realContextTokens)
        var assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let assistantID = assistant.id   // track by id, NOT a captured index — `messages` can be mutated

        var tokenCount = 0
        var hitDegeneration = false
        do {
            let stream = try await engine.generateChat(system: context.systemPrompt, history: windowed, options: options)
            for try await token in stream {
                // Dropping the iterator on break terminates the stream (the engine's
                // onTermination stops decoding), so Stop also stops the compute.
                if stopRequested { break }
                // Degeneration guard: if the tail is verbatim-looping despite the sampler's
                // repetition penalty, stop paying for tokens — the collapse below cleans up.
                tokenCount += 1
                if tokenCount % 32 == 0, DegenerationGuard.looksDegenerate(assistant.text) {
                    hitDegeneration = true
                    break
                }
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
            return
        }
        // Settle: collapse any exact-duplicate paragraph runs that slipped through (covers
        // the guard's between-checkpoints window and the Stop path alike), and never leave a
        // silently EMPTY bubble — an engine that produced zero tokens gets an honest notice.
        assistant.text = DegenerationGuard.collapseRepeatedParagraphs(assistant.text)
        if assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stopRequested {
            assistant.text = "The model returned an empty reply. Try rephrasing, or pick a larger model in the Model library."
        }
        // Token-cap mid-sentence → Continue. Count is per streamed piece from the UTF-8 decoder
        // (≈ per token on iOS). Not Stop, not degeneration, and we hit the budget.
        if !stopRequested, !hitDegeneration, tokenCount >= options.maxTokens {
            lastHitTokenCap = true
        }
        if let i = messages.firstIndex(where: { $0.id == assistantID }) { messages[i] = assistant }
    }

    /// Clear the conversation.
    public func reset() {
        // Q-322: cancel any in-flight decode BEFORE wiping its target array — otherwise the streaming
        // loop keeps appending tokens into a transcript that's just been replaced (cross-chat bleed).
        engine.requestCancel()
        lastHitTokenCap = false
        messages.removeAll()
    }

    /// Replace the transcript with a previously persisted conversation (see `ConversationStore`),
    /// so a chat picks up exactly where it left off after a relaunch.
    public func restore(_ saved: [ChatMessage]) {
        engine.requestCancel()   // Q-323: same — stop the decode before swapping the transcript out
        lastHitTokenCap = false
        messages = saved
    }
}
