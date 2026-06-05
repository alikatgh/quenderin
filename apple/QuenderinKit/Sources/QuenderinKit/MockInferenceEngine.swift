import Foundation

/// A canned `InferenceEngine` for SwiftUI previews, tests, and bringing up the
/// app shell before the llama.cpp binding exists. Streams a fixed reply
/// word-by-word to mimic token streaming. Never does real inference.
public actor MockInferenceEngine: InferenceEngine {
    private var loaded: String?
    private let cannedReply: String

    public init(cannedReply: String = "Hello from Quenderin — running fully on-device, offline.") {
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
        let reply = cannedReply
        return AsyncThrowingStream { continuation in
            let tokens = reply.split(separator: " ", omittingEmptySubsequences: false)
            for (index, token) in tokens.enumerated() {
                continuation.yield(index == 0 ? String(token) : " " + token)
            }
            continuation.finish()
        }
    }
}
