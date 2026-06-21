import Foundation

/// Chooses the right on-device engine for the current build, so callers never
/// hardcode a concrete runtime.
///
/// - When QuenderinKit is compiled with real llama.cpp linked — i.e. a build
///   that sets `QUENDERIN_LLAMA_DIR` (see `Package.swift`) or ships the per-arch
///   xcframework — `canImport(llama)` is true and `make()` returns the real
///   `LlamaEngine`, which does genuine on-device inference.
/// - Otherwise `make()` returns the `MockInferenceEngine`, so the full UI and
///   agent flow still build and run on a stub (no model file required).
///
/// This is the single seam the app, agent loop, and tests use to get "the best
/// available engine" without `#if canImport(llama)` scattered across the codebase.
public enum DefaultInferenceEngine {
    /// The best on-device engine available in this build (real when linked, mock otherwise).
    /// - Parameter contextTokens: device-tuned `n_ctx` (see `ContextWindow`); the mock ignores it.
    public static func make(contextTokens: Int32 = 4096) -> InferenceEngine {
        #if canImport(llama)
        return LlamaEngine(contextTokens: contextTokens)
        #else
        return MockInferenceEngine()
        #endif
    }

    /// `true` when this build links real llama.cpp — i.e. `make()` does real inference.
    /// Lets the UI honestly label whether it's running on-device or on the mock.
    public static var isReal: Bool {
        #if canImport(llama)
        true
        #else
        false
        #endif
    }
}
