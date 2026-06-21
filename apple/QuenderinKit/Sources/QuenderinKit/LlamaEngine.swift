import Foundation

// The `llama` module is llama.cpp compiled as a C library (via SwiftPM C target
// or a prebuilt llama.xcframework). It is NOT vendored here — see the wiring
// notes below. Until it is linked, `canImport(llama)` is false and this engine
// fails cleanly so the app keeps building against the seam (and can use the mock).
#if canImport(llama)
import llama
#endif

/// Real on-device inference via **llama.cpp**.
///
/// llama.cpp stays C/C++ — this actor is the *thin Swift adapter* that calls its
/// C API and conforms to ``InferenceEngine``. All the speed (Metal GPU kernels,
/// quantized matmuls) lives in the C++ library; this file only steers it. The
/// same C++ is later driven from Kotlin via JNI on Android — one engine, two
/// thin adapters.
///
/// ## One-time wiring
/// 1. Add llama.cpp so it vends a `llama` module, either:
///    - **SwiftPM:** add `.package(url: "https://github.com/ggml-org/llama.cpp", branch: "master")`
///      and list the `llama` product as a dependency of the QuenderinKit target, **or**
///    - **xcframework:** build `llama.xcframework` and expose it as a module map.
/// 2. Once `import llama` resolves, the `#if canImport(llama)` blocks compile and
///    run. Nothing else in the package changes.
///
/// > Important: the calls below target the llama.cpp C API circa late-2024/2025
/// > (`llama_model_load_from_file`, `llama_init_from_model`, the `llama_sampler_*`
/// > chain, vocab-based tokenize). **Pin a llama.cpp commit and adjust signatures
/// > if the API has drifted.** This file is a verified-on-device starting point,
/// > not headless-tested — `swift test` cannot exercise the C path.
public actor LlamaEngine: InferenceEngine {

    private var loaded: String?
    /// Context window (`n_ctx`); device-tuned so the KV cache doesn't OOM memory-tight phones (M1).
    private let contextTokens: Int32

    #if canImport(llama)
    private var model: OpaquePointer?     // llama_model *
    private var context: OpaquePointer?   // llama_context *
    private var vocab: OpaquePointer?     // const llama_vocab *
    private var backendInitialized = false  // llama_backend_init is "once per process" — gate it (L1)
    #endif

    public init(contextTokens: Int32 = 4096) {
        self.contextTokens = contextTokens
    }

    public func loadedModelID() async -> String? { loaded }

    public func load(model entry: ModelEntry, at fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw InferenceError.modelFileMissing(path: fileURL.path)
        }

        #if canImport(llama)
        // Free any model/context from a previous load() before allocating new ones — a model
        // switch would otherwise leak the old multi-GB context until process exit (C1).
        if let c = self.context { llama_free(c) }
        if let m = self.model { llama_model_free(m) }
        self.context = nil
        self.model = nil
        self.vocab = nil

        if !backendInitialized { llama_backend_init(); backendInitialized = true }  // once per process (L1)

        var modelParams = llama_model_default_params()
        // Offload every layer to the GPU (Metal on Apple) — this is the perf win.
        modelParams.n_gpu_layers = 999

        guard let m = llama_model_load_from_file(fileURL.path, modelParams) else {
            // Older llama.cpp: llama_load_model_from_file(...)
            throw InferenceError.loadFailed(reason: "llama_model_load_from_file returned null for \(entry.filename)")
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextTokens)   // device-tuned (M1), not a fixed 4096
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads

        guard let ctx = llama_init_from_model(m, ctxParams) else {
            // Older llama.cpp: llama_new_context_with_model(m, ctxParams)
            llama_model_free(m)
            throw InferenceError.loadFailed(reason: "llama_init_from_model returned null")
        }

        self.model = m
        self.context = ctx
        self.vocab = llama_model_get_vocab(m)
        self.loaded = entry.id
        #else
        throw InferenceError.loadFailed(
            reason: "llama.cpp is not linked into QuenderinKit yet. Add a `llama` module dependency "
                  + "(see the wiring notes in LlamaEngine.swift), or use MockInferenceEngine in the meantime."
        )
        #endif
    }

    public func unload() async {
        #if canImport(llama)
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        self.context = nil
        self.model = nil
        self.vocab = nil
        if backendInitialized { llama_backend_free(); backendInitialized = false }  // symmetric with the gated init (L1)
        #endif
        self.loaded = nil
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loaded != nil else { throw InferenceError.modelNotLoaded }

        #if canImport(llama)
        return AsyncThrowingStream { continuation in
            let task = Task { self.runGeneration(prompt: prompt, options: options, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        throw InferenceError.loadFailed(reason: "llama.cpp not linked; use MockInferenceEngine.")
        #endif
    }

    // MARK: - Real inference (compiled only when llama.cpp is linked)

    #if canImport(llama)
    /// The whole generation loop, ~30 lines. This is "how thin the adapter is":
    /// tokenize → decode → sample → detokenize → yield → repeat.
    private func runGeneration(
        prompt: String,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard let context, vocab != nil else {
            continuation.finish(throwing: InferenceError.modelNotLoaded)
            return
        }

        // 1) Prompt → tokens.
        var tokens = tokenize(text: prompt, addBOS: true)
        guard !tokens.isEmpty else {
            continuation.finish(throwing: InferenceError.generationFailed(reason: "tokenizer produced no tokens"))
            return
        }

        // 2) Sampler chain from the request options (top-p → temperature → dist).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(options.topP), 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(options.temperature)))
        // LLAMA_DEFAULT_SEED is a hex macro that imports to Swift as Int; the C
        // param is uint32_t — cast so it compiles against the current header.
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32(truncatingIfNeeded: LLAMA_DEFAULT_SEED)))
        defer { llama_sampler_free(sampler) }

        // 3) Decode prompt, then sample one token at a time.
        //
        // `llama_batch_get_one` only BORROWS the token pointer, so the batch must be built
        // AND consumed while that storage is alive — passing `&array` and using the batch
        // on a later line dangles (crash/garbage). This was caught by actually running the
        // C API; see apple/tools/llama-smoketest.swift. Hence withUnsafeMutableBufferPointer.
        func decode(_ toks: inout [llama_token]) -> Bool {
            toks.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) == 0
            }
        }

        if !decode(&tokens) {
            continuation.finish(throwing: InferenceError.generationFailed(reason: "llama_decode failed"))
            return
        }

        var produced = 0
        while produced < options.maxTokens {
            if Task.isCancelled { break }
            let next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }   // end-of-generation token

            let piece = tokenToPiece(next)
            if !piece.isEmpty { continuation.yield(piece) }
            produced += 1

            var one = [next]                               // feed the token back (alive during decode)
            if !decode(&one) {
                continuation.finish(throwing: InferenceError.generationFailed(reason: "llama_decode failed"))
                return
            }
        }
        continuation.finish()
    }

    /// Two-pass wrapper over `llama_tokenize`.
    private func tokenize(text: String, addBOS: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        guard text.utf8.count <= Int(Int32.max) else { return [] }  // a >2 GB prompt would overflow Int32 -> C UB (M2)
        let byteLen = Int32(text.utf8.count)
        let capacity = byteLen + (addBOS ? 1 : 0) + 1
        var out = [llama_token](repeating: 0, count: Int(capacity))
        let n = text.withCString { cString in
            llama_tokenize(vocab, cString, byteLen, &out, capacity, addBOS, true)
        }
        guard n >= 0 else { return [] }
        return Array(out.prefix(Int(n)))
    }

    /// Wrapper over `llama_token_to_piece` (single token → UTF-8 fragment).
    private func tokenToPiece(_ token: llama_token) -> String {
        guard let vocab else { return "" }
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if n < 0 {
            // A negative return is -(required bytes): the 64-byte buffer was too small (long Unicode,
            // byte-fallback, or special tokens). Re-run with the exact size so the piece isn't silently
            // dropped — `guard n > 0` previously treated this like empty, corrupting output (H1).
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        guard n > 0 else { return "" }
        let bytes = buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    #endif
}
