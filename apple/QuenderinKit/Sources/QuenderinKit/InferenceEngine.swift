import Foundation

/// Options for a single generation request. Mirrors the knobs the desktop
/// `LlmService` exposes; the llama.cpp engine maps these to its sampler.
public struct GenerationOptions: Sendable, Equatable {
    /// Only ordinary chat opts in. Raw agent/specialist requests never train model selection.
    public var collectPerformance: Bool
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    /// Top-k cutoff (0 = off). Qwen3's published recipe mandates `top_k=20` in every mode; the
    /// agent decode sets it so the free-form tail (a tool's `input` string) is sampled from the
    /// model's tuned distribution, not a looser one. Applied AFTER the grammar mask, so it only
    /// ever trims already-legal tokens — it can never make the JSON contract unsatisfiable.
    public var topK: Int
    /// Repetition penalty over the last `repeatLastN` tokens (1.0 = off). Without it the
    /// heavily-quantized small models loop the same paragraph verbatim — the failure mode
    /// is a wall of identical "Installing Python" sections, not subtle drift.
    public var repeatPenalty: Double
    public var repeatLastN: Int
    public var stopSequences: [String]
    /// A GBNF grammar to CONSTRAIN decoding (nil = unconstrained). Engines that support it
    /// (`LlamaEngine`) mask every token that can't continue the grammar — output that doesn't
    /// parse becomes unsampleable, the decoder-level fix for "the small model emitted prose
    /// instead of the JSON contract". Engines without grammar support ignore the field.
    public var gbnfGrammar: String?
    /// Controls `<think>…</think>` handling for chat templates that support thinking.
    /// Default `.off` preserves direct replies; agent/grammar/specialist paths always use `.off`.
    public var thinkingMode: ThinkingMode

    /// Defaults match `shared/sampling-profiles.json` → `chat` (CI: `check:sampling-parity`).
    public init(
        maxTokens: Int = 512,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        topK: Int = 40,
        repeatPenalty: Double = 1.1,
        repeatLastN: Int = 256,
        stopSequences: [String] = [],
        gbnfGrammar: String? = nil,
        collectPerformance: Bool = false,
        thinkingMode: ThinkingMode = .off
    ) {
        self.collectPerformance = collectPerformance
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.stopSequences = stopSequences
        self.gbnfGrammar = gbnfGrammar
        self.thinkingMode = thinkingMode
    }
}

/// Effective execution identity exposed by the engine, independent of observation storage.
public struct InferenceExecutionProfile: Sendable, Equatable {
    public let modelID: String
    public let artifactSHA256: String
    public let runtimeID: String
    public let backendID: String
    public let environmentID: String
    public let contextTokens: Int
    public let cacheMode: String
    public let promptTokens: Int?
    public let contextLengthChoice: ContextLengthChoice?
    public init(modelID: String, artifactSHA256: String, runtimeID: String, backendID: String,
                environmentID: String, contextTokens: Int, cacheMode: String = "cold", promptTokens: Int? = nil,
                contextLengthChoice: ContextLengthChoice? = nil) {
        self.modelID = modelID; self.artifactSHA256 = artifactSHA256; self.runtimeID = runtimeID
        self.backendID = backendID; self.environmentID = environmentID; self.contextTokens = contextTokens
        self.cacheMode = cacheMode; self.promptTokens = promptTokens
        self.contextLengthChoice = contextLengthChoice
    }
    func nextRequest(cacheMode: String, promptTokens: Int?) -> InferenceExecutionProfile {
        .init(modelID: modelID, artifactSHA256: artifactSHA256, runtimeID: runtimeID, backendID: backendID,
            environmentID: environmentID, contextTokens: contextTokens, cacheMode: cacheMode, promptTokens: promptTokens,
            contextLengthChoice: contextLengthChoice)
    }
}

public enum InferenceError: Error, Sendable, Equatable {
    case modelNotLoaded
    case modelFileMissing(path: String)
    case loadFailed(reason: String)
    case generationFailed(reason: String)
    case cancelled
    case timedOut(seconds: Int)
}

/// Why the most recent generation ended, for the "Continue" affordance.
///
/// `.hit` = positively observed token-budget stop. `.notHit` = positively observed non-budget
/// completion (EOG, context exhaustion, stop sequence/filter). `.unknown` = no trustworthy
/// observation: unsupported engine, no run yet, explicit cancellation, error, unloaded/stale.
/// Twin of Kotlin `ChatCapStatus`; never infer it from a streamed piece count.
public enum ChatCapStatus: Sendable, Equatable { case hit, notHit, unknown }

/// Runtime-agnostic contract for on-device LLM inference.
///
/// The chosen llama.cpp engine, a future MLX engine, and the mock below all
/// conform — so the app, the agent loop, and tests depend on this seam, never on
/// a concrete runtime. This is the boundary the native binding plugs into.
public protocol InferenceEngine: Sendable {
    /// id of the currently loaded model, or nil if none.
    func loadedModelID() async -> String?

    /// Load a model from a downloaded GGUF file. Throws if the file is missing
    /// or the runtime rejects it.
    func load(model: ModelEntry, at fileURL: URL) async throws

    /// Release the model and reclaim its memory.
    func unload() async

    /// Stream tokens as they are produced. Throws `.modelNotLoaded` if no model
    /// is loaded yet.
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error>

    /// Chat-structured streaming generation. Engines that know the model's own chat template
    /// (LlamaEngine, via the GGUF) format `history` with it — so the model answers as an
    /// assistant and STOPS at its end-of-turn token, instead of rambling hallucinated
    /// "User:/Assistant:" turns off a flat transcript. The default falls back to that flat
    /// transcript so mocks/scripted engines and tests are unchanged. Twin of Kotlin
    /// `InferenceEngine.completeChat`.
    func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error>

    /// Best-effort: interrupt an in-flight `generate` (e.g. a model switch or a stop button).
    /// Synchronous + non-blocking by design so it can signal a generation that holds the engine.
    /// Default no-op for engines that don't support interruption (mock, scripted, tests).
    func requestCancel()

    /// The ACTUAL context-window size (`n_ctx`, in tokens) of the LOADED model, or nil when unknown
    /// or nothing is loaded. The real engine sizes this from the device's memory at load — often
    /// 512–2048 on phones — so chat history must be trimmed to THIS, not a hardcoded 4096 that
    /// silently overflows the native window (Q-167, twin of Kotlin `loadedContextTokens`). The
    /// default nil keeps mock/scripted engines and their tests unchanged.
    func loadedContextTokens() async -> Int?
    /// Effective load configuration and expected reuse for the next structured request; no last-result statistics.
    func loadedExecutionProfile(system: String, history: [ChatMessage], options: GenerationOptions) async -> InferenceExecutionProfile?
    func knownExecutionProfiles() async -> [InferenceExecutionProfile]
    /// Retain the selected model across an entire local-agent run, including tool/approval gaps.
    func retainModelForAgentRun() async throws -> SpecialistInferenceLease
    /// Atomic idle-only model change. A shared agent/specialist generation must retain ownership.
    func loadForAutomaticIfIdle(model: ModelEntry, at fileURL: URL, stillCurrent: @escaping @Sendable () async -> Bool, accept: @escaping @Sendable () async -> Bool) async throws -> Bool
    func isSuspendedForSpecialist() async -> Bool
    func suspendForSpecialist() async throws -> SpecialistInferenceLease

    /// Why the most recent generation ended. Default `.unknown`: an engine that has not positively
    /// observed its completion reason must not turn "no cap signal" into a NOT_HIT claim.
    func chatCapStatus() async -> ChatCapStatus

    /// Preferred context-window choice applied on the next model load. Default `.auto`.
    func contextLengthChoice() async -> ContextLengthChoice
    func setContextLengthChoice(_ choice: ContextLengthChoice) async

    /// True while a generation, model load/switch, or specialist workflow currently holds the engine.
    func hasActiveInference() async -> Bool

    /// True when the rendered chat prompt for this request leaves an unclosed trailing `<think>`
    /// so streamed tokens begin already inside a thinking block. Default `false`.
    func chatPromptStartsInsideThinking(system: String, history: [ChatMessage], options: GenerationOptions) async -> Bool

    /// Acquires exclusive inference ownership (waiting up to `timeoutSeconds` if busy).
    /// Used by the macOS opt-in local API so chat and API requests never run the model concurrently.
    func acquireExclusiveInferenceLease(timeoutSeconds: Double) async throws -> ExclusiveInferenceLease

    /// Reserves exclusive ownership for a manual in-app model switch before cancelling ordinary
    /// chat or changing loading state. Waits up to `timeoutSeconds` if an active exclusive API
    /// turn currently owns the engine without cancelling that API turn.
    func acquireManualModelSwitchLease(timeoutSeconds: Double) async throws -> ExclusiveInferenceLease
}

/// Exclusive inference access granted by `InferenceEngine.acquireExclusiveInferenceLease(timeoutSeconds:)`.
public struct ExclusiveInferenceLease: Sendable {
    private let _loadedModelID: @Sendable () async -> String?
    private let _loadedExecutionProfile: @Sendable (String, [ChatMessage], GenerationOptions) async -> InferenceExecutionProfile?
    private let _load: @Sendable (ModelEntry, URL) async throws -> Void
    private let _setContextLengthChoice: @Sendable (ContextLengthChoice) async -> Void
    private let _chatPromptStartsInsideThinking: @Sendable (String, [ChatMessage], GenerationOptions) async -> Bool
    private let _generateChat: @Sendable (String, [ChatMessage], GenerationOptions) async throws -> AsyncThrowingStream<String, Error>
    private let _chatCapStatus: @Sendable () async -> ChatCapStatus
    private let _requestCancel: @Sendable () -> Void
    private let _release: @Sendable () async -> Void

    public init(
        loadedModelID: @escaping @Sendable () async -> String?,
        loadedExecutionProfile: @escaping @Sendable (String, [ChatMessage], GenerationOptions) async -> InferenceExecutionProfile?,
        generateChat: @escaping @Sendable (String, [ChatMessage], GenerationOptions) async throws -> AsyncThrowingStream<String, Error>,
        chatCapStatus: @escaping @Sendable () async -> ChatCapStatus,
        requestCancel: @escaping @Sendable () -> Void,
        release: @escaping @Sendable () async -> Void,
        load: @escaping @Sendable (ModelEntry, URL) async throws -> Void = { _, _ in throw SpecialistCoordinationError.unavailable },
        setContextLengthChoice: @escaping @Sendable (ContextLengthChoice) async -> Void = { _ in },
        chatPromptStartsInsideThinking: @escaping @Sendable (String, [ChatMessage], GenerationOptions) async -> Bool = { _, _, _ in false }
    ) {
        self._loadedModelID = loadedModelID
        self._loadedExecutionProfile = loadedExecutionProfile
        self._load = load
        self._setContextLengthChoice = setContextLengthChoice
        self._chatPromptStartsInsideThinking = chatPromptStartsInsideThinking
        self._generateChat = generateChat
        self._chatCapStatus = chatCapStatus
        self._requestCancel = requestCancel
        self._release = release
    }

    public func loadedModelID() async -> String? { await _loadedModelID() }
    public func loadedExecutionProfile(system: String, history: [ChatMessage], options: GenerationOptions) async -> InferenceExecutionProfile? {
        await _loadedExecutionProfile(system, history, options)
    }
    public func load(model: ModelEntry, at fileURL: URL) async throws {
        try await _load(model, fileURL)
    }
    public func setContextLengthChoice(_ choice: ContextLengthChoice) async {
        await _setContextLengthChoice(choice)
    }
    public func chatPromptStartsInsideThinking(system: String, history: [ChatMessage], options: GenerationOptions) async -> Bool {
        await _chatPromptStartsInsideThinking(system, history, options)
    }
    public func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try await _generateChat(system, history, options)
    }
    public func chatCapStatus() async -> ChatCapStatus { await _chatCapStatus() }
    public func requestCancel() { _requestCancel() }
    public func release() async { await _release() }
}

public extension InferenceEngine {
    func chatCapStatus() async -> ChatCapStatus { .unknown }
    func contextLengthChoice() async -> ContextLengthChoice { .auto }
    func setContextLengthChoice(_ choice: ContextLengthChoice) async {}
    func hasActiveInference() async -> Bool { false }
    func chatPromptStartsInsideThinking(system: String, history: [ChatMessage], options: GenerationOptions) async -> Bool { false }
    func acquireExclusiveInferenceLease(timeoutSeconds: Double) async throws -> ExclusiveInferenceLease {
        let cancelGate = NSLock()
        final class LeaseState: @unchecked Sendable { var active = true }
        let state = LeaseState()
        return ExclusiveInferenceLease(
            loadedModelID: { await self.loadedModelID() },
            loadedExecutionProfile: { system, history, options in
                await self.loadedExecutionProfile(system: system, history: history, options: options)
            },
            generateChat: { system, history, options in
                try await self.generateChat(system: system, history: history, options: options)
            },
            chatCapStatus: { await self.chatCapStatus() },
            requestCancel: {
                cancelGate.lock()
                defer { cancelGate.unlock() }
                guard state.active else { return }
                self.requestCancel()
            },
            release: {
                cancelGate.lock()
                state.active = false
                cancelGate.unlock()
            },
            load: { model, url in
                try await self.load(model: model, at: url)
            },
            setContextLengthChoice: { choice in
                await self.setContextLengthChoice(choice)
            },
            chatPromptStartsInsideThinking: { system, history, options in
                await self.chatPromptStartsInsideThinking(system: system, history: history, options: options)
            }
        )
    }
    func acquireManualModelSwitchLease(timeoutSeconds: Double) async throws -> ExclusiveInferenceLease {
        try await acquireExclusiveInferenceLease(timeoutSeconds: timeoutSeconds)
    }
}

/// The flat "User:/Assistant:" transcript prompt — the template-less fallback shared by the
/// protocol default and `LlamaEngine`'s no-template path.
func flatTranscriptPrompt(system: String, history: [ChatMessage]) -> String {
    var prompt = system.isEmpty ? "" : system + "\n\n"
    for m in history {
        prompt += (m.role == .user ? "User: " : "Assistant: ") + m.text + "\n"
    }
    prompt += "Assistant:"
    return prompt
}

public extension InferenceEngine {
    func retainModelForAgentRun() async throws -> SpecialistInferenceLease { SpecialistInferenceLease {} }
    func loadForAutomaticIfIdle(model: ModelEntry, at fileURL: URL, stillCurrent: @escaping @Sendable () async -> Bool, accept: @escaping @Sendable () async -> Bool) async throws -> Bool { false }
    func loadForAutomaticIfIdle(model: ModelEntry, at fileURL: URL) async throws -> Bool {
        try await loadForAutomaticIfIdle(model: model, at: fileURL, stillCurrent: { true }, accept: { true })
    }
    func loadedExecutionProfile(system: String, history: [ChatMessage], options: GenerationOptions) async -> InferenceExecutionProfile? { nil }
    func knownExecutionProfiles() async -> [InferenceExecutionProfile] { [] }
    func isSuspendedForSpecialist() async -> Bool { false }
    func suspendForSpecialist() async throws -> SpecialistInferenceLease { throw SpecialistCoordinationError.unavailable }
    func requestCancel() {}

    func loadedContextTokens() async -> Int? { nil }

    func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try await generate(prompt: flatTranscriptPrompt(system: system, history: history), options: options)
    }

    /// Convenience: accumulate the token stream into one completion string.
    func complete(prompt: String, options: GenerationOptions = .init()) async throws -> String {
        var output = ""
        for try await token in try await generate(prompt: prompt, options: options) {
            output += token
        }
        return output
    }
}
