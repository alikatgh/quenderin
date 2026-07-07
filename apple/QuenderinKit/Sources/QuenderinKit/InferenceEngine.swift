import Foundation

/// Options for a single generation request. Mirrors the knobs the desktop
/// `LlmService` exposes; the llama.cpp engine maps these to its sampler.
public struct GenerationOptions: Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
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

    public init(
        maxTokens: Int = 512,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        repeatPenalty: Double = 1.1,
        repeatLastN: Int = 256,
        stopSequences: [String] = [],
        gbnfGrammar: String? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.stopSequences = stopSequences
        self.gbnfGrammar = gbnfGrammar
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
