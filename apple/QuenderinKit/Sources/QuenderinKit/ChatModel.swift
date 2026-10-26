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
    ///
    /// The frame must ASSERT the text is readable: chat-tuned small models are trained to say
    /// "I can't open attachments", and a bare label + a low-content question ("?") reliably
    /// triggers that refusal even with the document right there in context (live find, 0.2.0(4):
    /// attach a PDF, send "?" → "I can't view or process attached files"). An explicit
    /// capability statement + end markers defeat the reflex, and an empty/punctuation-only
    /// question falls back to a concrete task so the model always has something to do.
    public var engineText: String {
        guard !documents.isEmpty else { return text }
        let docs = documents.map { doc in
            "The user attached the file \"\(doc.name)\". Its full extracted text is included "
            + "between the markers below — you can read it directly; use it to answer.\n"
            + "--- BEGIN \"\(doc.name)\" ---\n\(doc.text)\n--- END \"\(doc.name)\" ---"
        }.joined(separator: "\n\n")
        let ask = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRealAsk = ask.contains(where: { $0.isLetter || $0.isNumber })
        let question = hasRealAsk ? text : "Briefly summarize the attached file."
        return "\(docs)\n\n\(question)"
    }
}

public extension ChatMessage {
    /// True when this is an assistant message whose text trips `SafetyBlocklist` — the chat UI
    /// surfaces a non-blocking warning (`SupportContact.flaggedOutputNotice`) rather than
    /// suppressing it, the on-device "minimize risk" safeguard for the Generative-AI policies.
    /// User messages are never flagged. Kept in parity with Android `ChatMessage.isFlagged`.
    var isFlagged: Bool { role == .assistant && SafetyBlocklist.isBlocked(text) }
}

/// Where generation is in its lifecycle — drives honest UI during long prefill.
public enum GenerationPhase: String, Sendable, Equatable {
    case idle
    /// Engine is processing the prompt (no tokens yet) — can take seconds on phones.
    case loadingPrompt
    /// First token has arrived; the reply is streaming.
    case writing
}

/// Composer lifetime follows the conversation owner, including view removal during a manual handoff.
@MainActor
public final class ChatComposerState: ObservableObject {
    @Published public var draft = ""
    @Published public var pendingDocuments: [AttachedDocument] = []
    @Published public var attachmentNotice: String?
    public init() {}
    struct Snapshot {
        var draft = ""
        var documents: [AttachedDocument] = []
        var notice: String?
        var isEmpty: Bool { draft.isEmpty && documents.isEmpty && notice == nil }
    }
    func snapshot() -> Snapshot { Snapshot(draft: draft, documents: pendingDocuments, notice: attachmentNotice) }
    func restore(_ snapshot: Snapshot) {
        draft = snapshot.draft; pendingDocuments = snapshot.documents; attachmentNotice = snapshot.notice
    }
}

/// A generation-independent guard and ephemeral pending history. No content enters performance storage.
public struct ChatPreparationContext: Sendable {
    public let history: [ChatMessage]
    public let options: GenerationOptions?
    public let isCurrent: @MainActor @Sendable () -> Bool
    public init(history: [ChatMessage] = [], options: GenerationOptions? = nil, isCurrent: @escaping @MainActor @Sendable () -> Bool) {
        self.history = history; self.options = options; self.isCurrent = isCurrent
    }
}

/// Drives a chat conversation against any `InferenceEngine`, appending tokens to
/// the in-flight assistant message as they stream in. Runs on the mock engine
/// today; swaps to `LlamaEngine` with no change.
@MainActor
public final class ChatModel: ObservableObject {
    public let composer = ChatComposerState()
    /// false=new/guided-only; true=accepted ordinary inference; nil=legacy history with unknown provenance.
    public private(set) var hasOrdinaryInference: Bool? = false
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isGenerating = false
    /// Prefill vs decode — UI shows "Loading prompt…" until the first token, then "Writing…".
    @Published public private(set) var generationPhase: GenerationPhase = .idle
    /// True when the last settled reply stopped because it hit `options.maxTokens` (not Stop, not
    /// EOG). The chat UI surfaces a "Continue" chip so a mid-sentence cut is recoverable
    /// (KNOWN_FAILURE_MODES). Cleared on the next send / reset / restore.
    @Published public private(set) var lastHitTokenCap = false

    /// Set by `stopGenerating()`; checked per token so a stop lands within one token.
    private var stopRequested = false
    private var conversationRevision: UInt64 = 0

    /// The assistant message owned by the send that is still streaming, or nil when the transcript
    /// has no unsettled turn. While it is set, `completedMessages` excludes it and
    /// `abandonInFlightTurn` removes it, so a partial reply the user navigated away from is never
    /// persisted as a finished turn. Cleared by a normal settle, by `reset`/`restore`, and by
    /// abandonment. An explicit Stop keeps it (the partial becomes the user's answer).
    private var inFlightAssistantID: UUID?

    /// True once the user explicitly stopped the current reply. An explicitly stopped partial is a
    /// finished answer: it stays in the transcript and is persistable even while the stream unwinds.
    public var didRequestStop: Bool { stopRequested }

    /// Monotonic count of transcript edits and removals (not appends). The
    /// coordinator saves again when a settle changed the text without changing the message count.
    public private(set) var transcriptRevision: UInt64 = 0

    /// Stop the current reply where it is — the streamed partial stays in the transcript
    /// (stopping is a decision about YOUR time, not a failure; no error styling), and it remains
    /// persistable: `completedMessages` includes it once `stopRequested` is set.
    ///
    /// Transcript ownership is retained until the send settles the text accepted BEFORE the Stop
    /// exactly once; a concurrent `send` is a no-op meanwhile. An engine may ignore
    /// `requestCancel` — nothing here promises a cancellation latency, and the turn stays busy
    /// until the engine actually returns.
    public func stopGenerating() {
        conversationRevision &+= 1   // active AND idle: reject queued/prepared admissions
        guard isGenerating, !stopRequested else { return }
        stopRequested = true
        engine.requestCancel()
    }

    /// Messages that belong to SETTLED turns — the only transcript a caller may persist. While a
    /// reply streams, its assistant message is excluded; an explicit Stop makes the accepted partial
    /// persistable immediately (ownership is retained only to settle its text). Twin of Kotlin
    /// `ChatModel.completedMessages`.
    public func completedMessages() -> [ChatMessage] {
        guard let pending = inFlightAssistantID, !stopRequested else { return messages }
        return messages.filter { $0.id != pending }
    }

    /// Atomic persistence snapshot: the completed transcript AND the text revision it reflects.
    /// Reading them separately could record a revision newer than the saved text, so a count-only
    /// check would never save the corrected text. Twin of Kotlin `ChatModel.persistSnapshot`.
    public func persistSnapshot() -> ([ChatMessage], UInt64) {
        (completedMessages(), transcriptRevision)
    }

    /// Abandon the unsettled turn (Back, new chat, open another conversation): stop the decode and
    /// REMOVE the partial assistant message, so it is neither shown as an answer nor persisted later
    /// when the stream settles. Explicit Stop is different — `stopGenerating` keeps the partial.
    /// Twin of Kotlin `ChatModel.invalidatePreparedTurns`.
    public func abandonInFlightTurn() {
        stopRequested = true          // also invalidates a prepared-but-unstarted turn
        engine.requestCancel()
        guard let pending = inFlightAssistantID else { return }
        inFlightAssistantID = nil
        if let index = messages.firstIndex(where: { $0.id == pending }) {
            messages.remove(at: index)
            transcriptRevision &+= 1   // replace an interim durable Stop partial on navigation
        }
    }

    /// Extend the previous reply after a token-cap stop. Sends a short continue cue so the model
    /// picks up mid-thought. No-op when `lastHitTokenCap` is false.
    ///
    /// - Parameter model: the model that produced the reply being continued — forwarded to
    ///   `send()` so the continuation uses the SAME tier (system prompt + token budget) as the
    ///   turn it's extending, instead of `send()`'s `model: nil` default (which resolves to
    ///   `.small` regardless of what actually generated the original reply).
    public func continueLast(options: GenerationOptions = .init(), model: ModelEntry? = nil) async {
        guard lastHitTokenCap, !isGenerating else { return }
        await send(ChatUserFacing.continueCue(), options: options, model: model)
    }

    @Published public private(set) var automaticSelectionStatus: String?
    @Published public private(set) var preparationError: String?
    private let admitTurn: (@MainActor () throws -> Void)?
    private let prepareFirstTurn: (@MainActor (String, ModelEntry?, ChatPreparationContext) async throws -> (ModelEntry?, String?))?
    var prepareRestoredModel: (@MainActor (ModelEntry?, ChatPreparationContext) async throws -> ModelEntry?)?
    var didAcceptModel: (@MainActor (ModelEntry?, Bool) -> Void)?
    var didRecordGuidedTurn: (@MainActor () -> Void)?
    private let engine: InferenceEngine
    private let context: ConversationContext

    public init(engine: InferenceEngine, context: ConversationContext = .init(),
                admitTurn: (@MainActor () throws -> Void)? = nil,
                prepareFirstTurn: (@MainActor (String, ModelEntry?, ChatPreparationContext) async throws -> (ModelEntry?, String?))? = nil) {
        self.admitTurn = admitTurn
        self.prepareFirstTurn = prepareFirstTurn
        self.engine = engine
        self.context = context
    }

    /// Record a user turn + a fixed assistant reply without calling the model. Used when chat
    /// detects a computer task (`ActionIntent`) so the user gets education + a handoff button
    /// instead of a generated "I cannot fulfill that request" wall.
    public func recordGuidedTurn(userText: String, documents: [AttachedDocument] = [],
                                 assistantText: String) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !documents.isEmpty, !isGenerating else { return }
        messages.append(ChatMessage(role: .user, text: trimmed, documents: documents))
        messages.append(ChatMessage(role: .assistant, text: assistantText))
        didRecordGuidedTurn?()
    }

    /// Send a prompt and stream the reply. No-ops on empty input (unless documents are
    /// attached — "summarize this file" with no extra words is a legitimate send) or while a
    /// previous generation is still running.
    ///
    /// - Parameter model: when set, applies [ChatTier] maxTokens + system-prompt suffix for that
    ///   model's size class (1B stays short; 7B+ gets full budget).
    public func send(
        _ prompt: String,
        documents: [AttachedDocument] = [],
        options: GenerationOptions? = nil,
        model: ModelEntry? = nil,
        onAccepted: (() -> Void)? = nil
    ) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !documents.isEmpty, !isGenerating else { return }

        isGenerating = true
        generationPhase = .loadingPrompt
        stopRequested = false
        defer {
            isGenerating = false
            generationPhase = .idle
        }

        let turnRevision = conversationRevision
        preparationError = nil
        var selectedModel = model
        let pendingHistory = (messages + [ChatMessage(role: .user, text: trimmed, documents: documents)]).map { message in
            guard !message.documents.isEmpty else { return message }
            return ChatMessage(id: message.id, role: message.role, text: message.engineText)
        }
        let preparation = ChatPreparationContext(history: pendingHistory, options: options) { self.conversationRevision == turnRevision && !self.stopRequested }
        var automaticSelected = false
        do {
            try admitTurn?()
            if !messages.isEmpty, let prepareRestoredModel {
                selectedModel = try await prepareRestoredModel(model, preparation)
                if let selectedModel { automaticSelectionStatus = "\(selectedModel.label) · selected local model" }
            }
            if hasOrdinaryInference == false, let prepareFirstTurn {
                let prepared = try await prepareFirstTurn(ChatMessage(role: .user, text: trimmed, documents: documents).engineText, selectedModel, preparation)
                selectedModel = prepared.0
                automaticSelectionStatus = prepared.1
                automaticSelected = prepared.1 != nil
            }
            guard preparation.isCurrent(), !Task.isCancelled else { return }
        } catch {
            guard conversationRevision == turnRevision else { return }
            preparationError = error is CancellationError
                ? "Model selection changed. Your message and attachments are kept; send again when ready."
                : "The selected model is unavailable. Your message and attachments are kept. " + OnboardingModel.describe(error)
            return
        }
        let tier = ChatTier.of(model: selectedModel)
        var resolvedOptions = options ?? tier.chatOptions
        resolvedOptions.collectPerformance = true
        let systemPrompt = tier.systemPrompt

        // The engine's REAL loaded `n_ctx` (often 512–2048 on phones), so the history trim below
        // matches the actual native window instead of the configured 4096 (Q-167 — Android had this,
        // iOS didn't; twin-drift audit). Awaited BEFORE any transcript mutation and only AFTER
        // `isGenerating` is set: every await yields the main actor, and a reentrant send must not
        // slip past the guard (the @MainActor+await journal pattern).
        let realContextTokens = await engine.loadedContextTokens()

        guard !stopRequested, !Task.isCancelled, conversationRevision == turnRevision else { return }
        do { try admitTurn?() }
        catch {
            preparationError = "The local model is still being prepared. Your message and attachments are kept. " + OnboardingModel.describe(error)
            return
        }
        lastHitTokenCap = false
        hasOrdinaryInference = true
        didAcceptModel?(selectedModel, automaticSelected)
        onAccepted?()
        messages.append(ChatMessage(role: .user, text: trimmed, documents: documents))
        // Chat-structured generation: pass the budget-windowed history so the engine formats it
        // with the model's OWN chat template (answers as an assistant, stops at end-of-turn).
        // Template-less engines fall back to the flat transcript; the assistant remembers prior
        // turns either way. Attached documents are composed in (engineText) BEFORE windowing so
        // the token budget counts them.
        let budgetContext = ConversationContext(
            systemPrompt: systemPrompt,
            contextTokens: context.contextTokens,
            reservedForResponse: context.reservedForResponse
        )
        let windowed = budgetContext.windowedHistory(messages.map { message in
            guard !message.documents.isEmpty else { return message }
            var composed = message
            composed.text = message.engineText
            composed.documents = []
            return composed
        }, contextTokensOverride: realContextTokens)
        var assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let assistantID = assistant.id   // track by id, NOT a captured index — `messages` can be mutated
        inFlightAssistantID = assistantID

        var tokenCount = 0
        var hitDegeneration = false
        // Pace transcript writes to display frames (~30 Hz): every write is a full list diff plus a
        // Markdown re-parse of the reply, and at 80 tok/s that — not the engine — is the stall users
        // see. The first piece always lands; the settle write below always lands (StreamFlushGate).
        var flushGate = StreamFlushGate()
        do {
            let stream = try await engine.generateChat(system: systemPrompt, history: windowed, options: resolvedOptions)
            for try await token in stream {
                // Dropping the iterator on break terminates the stream (the engine's
                // onTermination stops decoding), so Stop also stops the compute.
                if stopRequested { break }
                // Degeneration guard: if the tail is verbatim-looping despite the sampler's
                // repetition penalty, stop paying for tokens — the collapse below cleans up.
                tokenCount += 1
                if tokenCount == 1 { generationPhase = .writing }
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
                if flushGate.shouldFlush(), messages[i].text != assistant.text {
                    messages[i] = assistant
                    transcriptRevision &+= 1
                }
            }
        } catch {
            // A stale A must not write or clear a newer B's ownership.
            guard inFlightAssistantID == assistantID else { return }
            if stopRequested {
                // Explicit Stop: the accepted pre-Stop text is the answer, even when the engine
                // reports cancellation by throwing. Collapse and write it; no warning/notice/cap.
                assistant.text = DegenerationGuard.collapseRepeatedParagraphs(assistant.text)
                if let i = messages.firstIndex(where: { $0.id == assistantID }),
                   messages[i].text != assistant.text {
                    messages[i] = assistant
                    transcriptRevision &+= 1
                }
                inFlightAssistantID = nil
                return
            }
            if error is CancellationError || Task.isCancelled {
                // Coroutine/lifecycle cancellation: keep the accepted partial unsettled and do not
                // fabricate a warning. Navigation abandons it; a later send starts cleanly.
                return
            }
            assistant.text = "⚠️ " + OnboardingModel.describe(error)
            if let i = messages.firstIndex(where: { $0.id == assistantID }), messages[i].text != assistant.text {
                messages[i] = assistant
                transcriptRevision &+= 1
            }
            inFlightAssistantID = nil   // the error notice is the settled answer for this turn
            return
        }
        // Settle: collapse any exact-duplicate paragraph runs that slipped through (covers
        // the guard's between-checkpoints window and the Stop path alike), and never leave a
        // silently EMPTY bubble — an engine that produced zero tokens gets an honest notice.
        assistant.text = DegenerationGuard.collapseRepeatedParagraphs(assistant.text)
        if assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stopRequested {
            assistant.text = ChatUserFacing.emptyReply()
        }
        // Token-cap mid-sentence → Continue. Count is per streamed piece from the UTF-8 decoder
        // (≈ per token on iOS). Not Stop, not degeneration, and we hit the budget.
        if !stopRequested, !hitDegeneration, tokenCount >= resolvedOptions.maxTokens {
            lastHitTokenCap = true
        }
        if let i = messages.firstIndex(where: { $0.id == assistantID }) {
            if messages[i].text != assistant.text {
                messages[i] = assistant
                transcriptRevision &+= 1
            }
            inFlightAssistantID = nil   // normal settle: this turn is a finished answer
        }
    }

    func invalidatePendingPreparation() { conversationRevision &+= 1 }

    /// Clear the conversation.
    public func reset() {
        hasOrdinaryInference = false
        conversationRevision &+= 1
        preparationError = nil; automaticSelectionStatus = nil
        // Q-322: cancel any in-flight decode BEFORE wiping its target array — otherwise the streaming
        // loop keeps appending tokens into a transcript that's just been replaced (cross-chat bleed).
        if !messages.isEmpty { engine.requestCancel() }
        lastHitTokenCap = false
        inFlightAssistantID = nil
        messages.removeAll()
    }

    /// Replace the transcript with a previously persisted conversation (see `ConversationStore`),
    /// so a chat picks up exactly where it left off after a relaunch.
    public func restore(_ saved: [ChatMessage], hasOrdinaryInference: Bool? = nil) {
        self.hasOrdinaryInference = hasOrdinaryInference
        conversationRevision &+= 1
        preparationError = nil; automaticSelectionStatus = nil
        engine.requestCancel()   // Q-323: same — stop the decode before swapping the transcript out
        lastHitTokenCap = false
        inFlightAssistantID = nil
        messages = saved
    }
}
