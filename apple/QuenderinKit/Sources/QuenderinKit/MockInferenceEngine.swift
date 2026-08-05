import Foundation

/// A canned `InferenceEngine` for SwiftUI previews, tests, and bringing up the
/// app shell before the llama.cpp binding exists. Streams a reply word-by-word
/// to mimic token streaming. Never does real inference.
///
/// - Parameter cannedReply: when non-`nil`, always return that string (tests inject exact text).
///   When `nil` (default), [DemoMockReplies] picks an honest demo answer from the prompt so
///   starter chips feel usable without a native engine.
public actor MockInferenceEngine: InferenceEngine {
    private var loaded: String?
    private let cannedReply: String?

    public init(cannedReply: String? = nil) {
        self.cannedReply = cannedReply
    }

    public func loadedModelID() async -> String? { loaded }

    public func load(model: ModelEntry, at fileURL: URL) async throws {
        loaded = model.id
    }

    public func unload() async {
        loaded = nil
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loaded != nil else { throw InferenceError.modelNotLoaded }
        let reply = cannedReply ?? DemoMockReplies.reply(for: prompt)
        return AsyncThrowingStream { continuation in
            let tokens = reply.split(separator: " ", omittingEmptySubsequences: false)
            for (index, token) in tokens.enumerated() {
                continuation.yield(index == 0 ? String(token) : " " + token)
            }
            continuation.finish()
        }
    }
}
