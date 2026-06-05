import Foundation

/// Options for a single generation request. Mirrors the knobs the desktop
/// `LlmService` exposes; the llama.cpp engine maps these to its sampler.
public struct GenerationOptions: Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var stopSequences: [String]

    public init(
        maxTokens: Int = 512,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        stopSequences: [String] = []
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
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
}

public extension InferenceEngine {
    /// Convenience: accumulate the token stream into one completion string.
    func complete(prompt: String, options: GenerationOptions = .init()) async throws -> String {
        var output = ""
        for try await token in try await generate(prompt: prompt, options: options) {
            output += token
        }
        return output
    }
}
