import Foundation

/// An `InferenceEngine` that returns a fixed queue of replies in order — so
/// multi-turn agent loops can be tested (and previewed) deterministically,
/// without a real model. Once the script is exhausted it returns a final-answer
/// JSON so loops terminate cleanly.
public actor ScriptedInferenceEngine: InferenceEngine {
    private var replies: [String]
    private var loaded: String? = "scripted"

    public init(replies: [String]) {
        self.replies = replies
    }

    public func loadedModelID() async -> String? { loaded }
    public func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
    public func unload() async { loaded = nil }

    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        let next = replies.isEmpty ? "{\"answer\":\"(no more scripted replies)\"}" : replies.removeFirst()
        return AsyncThrowingStream { continuation in
            continuation.yield(next)
            continuation.finish()
        }
    }
}
