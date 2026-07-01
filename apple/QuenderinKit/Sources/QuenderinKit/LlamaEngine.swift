import Foundation
import os

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
/// ## Concurrency model
/// The native handles are `nonisolated(unsafe)` and guarded by `nativeLock`, so a
/// **generation runs OFF the actor's cooperative thread pool** (audit M2) on a
/// background queue, while `nativeLock` still serializes load / unload / generate —
/// a switch can't free the context mid-decode (the same use-after-free guard Android
/// gets from `synchronized`; C1/C2). `cancelState` lets `load()`/`unload()`/an explicit
/// `requestCancel()` interrupt a running generation (audit M3). The async actor methods
/// keep the lock inside synchronous helpers (manual `NSLock` is banned in async contexts).
///
/// > Important: targets the llama.cpp C API circa late-2024/2025. Pin a commit and adjust
/// > signatures if the API has drifted.
public actor LlamaEngine: InferenceEngine {

    private var loaded: String?
    /// Device app-memory budget (GB); `n_ctx` is sized from this + the model's footprint at load so
    /// the KV cache doesn't OOM memory-tight phones (M1 + footprint-aware).
    private let deviceBudgetGB: Double

    #if canImport(llama)
    nonisolated(unsafe) private var model: OpaquePointer?     // llama_model *
    nonisolated(unsafe) private var context: OpaquePointer?   // llama_context *
    nonisolated(unsafe) private var vocab: OpaquePointer?     // const llama_vocab *
    nonisolated(unsafe) private var backendInitialized = false  // llama_backend_init is once-per-process (L1)
    /// The unthrottled (P-core) thread count chosen at load — the governor's baseline for in-flight
    /// thermal re-tuning during generation. Set under `nativeLock`; read at the start of a decode.
    nonisolated(unsafe) private var loadedBaseThreads = 1
    /// The exact token sequence currently resident in the context's KV cache (prior prompt + reply).
    /// Lets a new chat turn reuse the cache and decode only the new suffix instead of re-prefilling the
    /// whole history (`KVCacheReuse`). Kept in lockstep with the KV by construction; reset on load/unload.
    nonisolated(unsafe) private var cachedTokens: [llama_token] = []
    /// Serializes every native access (load/unload/generate) so freeing can't race a decode (C1/C2).
    private let nativeLock = NSLock()
    /// Set true to interrupt a running generation (model switch / explicit cancel) — M3.
    private let cancelState = OSAllocatedUnfairLock(initialState: false)
    #endif

    public init(deviceBudgetGB: Double = 4.0) {
        self.deviceBudgetGB = deviceBudgetGB
    }

    public func loadedModelID() async -> String? { loaded }

    public func load(model entry: ModelEntry, at fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw InferenceError.modelFileMissing(path: fileURL.path)
        }
        #if canImport(llama)
        cancelState.withLock { $0 = true }   // stop any running generation before we free the context
        loaded = nil                         // nothing loaded until the new model succeeds
        try loadLocked(entry: entry, path: fileURL.path)
        loaded = entry.id
        #else
        throw InferenceError.loadFailed(
            reason: "llama.cpp is not linked into QuenderinKit yet. Add a `llama` module dependency "
                  + "(see the wiring notes in LlamaEngine.swift), or use MockInferenceEngine in the meantime."
        )
        #endif
    }

    public func unload() async {
        #if canImport(llama)
        cancelState.withLock { $0 = true }
        unloadLocked()
        #endif
        loaded = nil
    }

    /// Best-effort: interrupt an in-flight `generate` (e.g. a stop button). The switch path
    /// already cancels inside `load()`/`unload()`; this is for explicit user cancellation (M3).
    public nonisolated func requestCancel() {
        #if canImport(llama)
        cancelState.withLock { $0 = true }
        #endif
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loaded != nil else { throw InferenceError.modelNotLoaded }
        #if canImport(llama)
        cancelState.withLock { $0 = false }   // fresh generation
        return AsyncThrowingStream { continuation in
            // Run the decode OFF the cooperative pool (M2) so a multi-second generation doesn't
            // pin a Swift-concurrency thread; `nativeLock` (acquired inside) keeps it safe.
            DispatchQueue.global(qos: .userInitiated).async {
                self.runGeneration(prompt: prompt, options: options, into: continuation)
            }
            continuation.onTermination = { _ in self.cancelState.withLock { $0 = true } }
        }
        #else
        throw InferenceError.loadFailed(reason: "llama.cpp not linked; use MockInferenceEngine.")
        #endif
    }

    // MARK: - Real inference (compiled only when llama.cpp is linked)

    #if canImport(llama)
    /// The native load, under `nativeLock` (synchronous → manual lock is allowed here, unlike the
    /// async `load()`). Frees any previous model first (free-before-reassign; C1) and throws on
    /// failure, leaving `model`/`context`/`vocab` nil so the engine reports "not loaded".
    nonisolated private func loadLocked(entry: ModelEntry, path: String) throws {
        nativeLock.lock()
        defer { nativeLock.unlock() }

        if let c = context { llama_free(c) }
        if let m = model { llama_model_free(m) }
        context = nil
        model = nil
        vocab = nil

        if !backendInitialized { llama_backend_init(); backendInitialized = true }  // once per process (L1)

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999   // offload every layer to the GPU (Metal on Apple)
        // Jetsam guard for this project's target class (memory-tight phones under background
        // pressure): mmap keeps the weights pageable (fast cold start, reclaimable by the OS), and
        // mlock is explicitly OFF — wiring multi-GB of weights resident is exactly what gets the app
        // jetsam-killed when the user switches to music/maps. Pin the safe default so it can't regress.
        modelParams.use_mmap = true
        modelParams.use_mlock = false

        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw InferenceError.loadFailed(reason: "llama_model_load_from_file returned null for \(entry.filename)")
        }

        var ctxParams = llama_context_default_params()
        // KV-cache dtype from the headroom after weights: tight phones get a q8_0 cache (~half the
        // per-token memory, near-lossless), which the cache-aware n_ctx then turns into ~2× context.
        let kvCacheType = KVCachePolicy.recommend(appBudgetGB: deviceBudgetGB, modelWeightsGB: entry.ramGB)
        // n_ctx from the real app-memory budget, this model's footprint, AND the cache dtype
        // (footprint-aware M1): a 1B gets a big context, a 7B on the same phone is capped tight.
        let nctx = ContextWindow.recommend(
            appBudgetGB: deviceBudgetGB, modelWeightsGB: entry.ramGB, kvCacheType: kvCacheType)
        ctxParams.n_ctx = UInt32(nctx)
        // q8_0 is safe for both K and V on the standard (non-flash-attention) path.
        let ggmlCacheType: ggml_type = (kvCacheType == .q8_0) ? GGML_TYPE_Q8_0 : GGML_TYPE_F16
        ctxParams.type_k = ggmlCacheType
        ctxParams.type_v = ggmlCacheType
        // Performance-core count, not all cores — E-cores slow + heat up mobile decode.
        let baseThreads = ThreadPlanner.recommend(
            performanceCores: HardwareProbe.performanceCoreCount(),
            totalCores: ProcessInfo.processInfo.activeProcessorCount)
        loadedBaseThreads = baseThreads   // governor baseline for in-flight thermal re-tuning
        // If the device is already thermally throttling when we load, start with fewer threads
        // so a long generation stays sustainable instead of spiking heat and getting killed.
        let threads = Int32(ThermalThrottle.recommendedThreads(
            level: ThermalMonitor.currentLevel(), baseThreads: baseThreads))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads
        // (Metal flash-attention is a further ~15-25% win but the field name varies across
        //  llama.cpp versions — enable it once the pinned commit's `llama_context_params` is known.)

        guard let ctx = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            throw InferenceError.loadFailed(reason: "llama_init_from_model returned null")
        }

        model = m
        context = ctx
        vocab = llama_model_get_vocab(m)
        cachedTokens = []   // fresh context ⇒ empty KV cache
    }

    /// The native unload, under `nativeLock` (synchronous).
    nonisolated private func unloadLocked() {
        nativeLock.lock()
        defer { nativeLock.unlock() }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        cachedTokens = []
        if backendInitialized { llama_backend_free(); backendInitialized = false }  // symmetric with the gated init (L1)
    }

    /// The whole generation loop: tokenize → decode → sample → detokenize → yield → repeat. Runs
    /// on a background queue under `nativeLock` so it can't race a load()/unload() free.
    nonisolated private func runGeneration(
        prompt: String,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        nativeLock.lock()
        defer { nativeLock.unlock() }

        guard let context, vocab != nil else {
            continuation.finish(throwing: InferenceError.modelNotLoaded)
            return
        }

        // 1) Prompt → tokens.
        let newTokens = tokenize(text: prompt, addBOS: true)
        guard !newTokens.isEmpty else {
            continuation.finish(throwing: InferenceError.generationFailed(reason: "tokenizer produced no tokens"))
            return
        }

        // 2) Sampler chain from the request options (top-p → temperature → dist).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(options.topP), 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(options.temperature)))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32(truncatingIfNeeded: LLAMA_DEFAULT_SEED)))
        defer { llama_sampler_free(sampler) }

        // 3) Decode prompt, then sample one token at a time.
        //
        // `llama_batch_get_one` only BORROWS the token pointer, so the batch must be built AND
        // consumed while that storage is alive — hence withUnsafeMutableBufferPointer.
        //
        // Returns the raw llama_decode rc (0 = ok, 1 = no free KV slot — cache full, recoverable,
        // negative = fatal) — NOT collapsed to Bool, so callers can distinguish a graceful
        // context-limit stop from a genuine failure, mirroring llama_generate.h's contract.
        func decode(_ toks: inout [llama_token]) -> Int32 {
            toks.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
            }
        }

        // Reuse the KV cache from the prior turn: decode only the tokens NOT already cached, so
        // time-to-first-token doesn't grow with conversation length (KVCacheReuse). Beyond a pure
        // append, a front-drop (the context window slid and evicted the oldest turn) is handled by a
        // context-shift — physically evict the dropped middle and shift the survivors' positions down —
        // instead of re-prefilling the whole window every turn. Fail-safe: the reused region is always
        // token-for-token identical to the new prompt, and if the cache type can't do a partial
        // removal (e.g. SWA) we fall back to a clean full reprefill. Twin of llama_generate.h.
        let mem = llama_get_memory(context)
        let plan = KVCacheReuse.plan(cached: cachedTokens, new: newTokens)
        var reuse = plan.decodeFrom
        if plan.clearCache {
            llama_memory_clear(mem, true)
            reuse = 0
        } else if plan.evictFrom < plan.evictTo {
            // seq_rm drops the evicted middle; seq_add shifts [evictTo, ∞) down to close the gap
            // (RoPE-corrected). seq_rm returns false when partial removal isn't supported → full reprefill.
            let from = llama_pos(plan.evictFrom)
            let to = llama_pos(plan.evictTo)
            if llama_memory_seq_rm(mem, 0, from, to) {
                llama_memory_seq_add(mem, 0, to, -1, -(to - from))
            } else {
                llama_memory_clear(mem, true)
                reuse = 0
            }
        }
        var toPrefill = Array(newTokens[reuse...])
        var prefillRC = decode(&toPrefill)
        if prefillRC == 1 && reuse > 0 {
            // Cache full with the reused prefix in play — drop reuse and reprefill the whole
            // turn fresh (mirrors llama_generate.h).
            llama_memory_clear(mem, true)
            cachedTokens = []
            toPrefill = newTokens
            reuse = 0
            prefillRC = decode(&toPrefill)
        }
        if prefillRC != 0 {
            llama_memory_clear(llama_get_memory(context), true)
            cachedTokens = []
            continuation.finish(throwing: InferenceError.generationFailed(reason: "llama_decode failed"))
            return
        }
        cachedTokens = newTokens   // the KV cache now holds exactly `newTokens`

        // In-flight thermal governor: as a long generation heats the SoC, shed threads so it
        // sustains instead of throttling to a crawl. Sampled every 32 tokens (the read is cheap and
        // heat moves slowly), and only re-tunes when the level actually changes (M3 thermal).
        var governor = ThermalGovernor(baseThreads: loadedBaseThreads, initialLevel: ThermalMonitor.currentLevel())
        let thermalSampleInterval = 32

        var produced = 0
        var yieldedAnyText = false   // mirrors llama_generate.h's `out.empty()` — true once ANY non-empty
                                      // piece has been yielded, INCLUDING the current token's (checked
                                      // below only after this token's own yield, same ordering as the
                                      // C++ `out += piece` happening before the fatal check).
        while produced < options.maxTokens {
            if cancelState.withLock({ $0 }) { break }   // interrupted by a switch/cancel (M3)
            if produced % thermalSampleInterval == 0,
               let retuned = governor.update(level: ThermalMonitor.currentLevel()) {
                llama_set_n_threads(context, Int32(retuned), Int32(retuned))
            }
            let next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }   // end-of-generation token

            let piece = tokenToPiece(next)
            if !piece.isEmpty {
                continuation.yield(piece)
                yieldedAnyText = true
            }
            produced += 1

            var one = [next]                               // feed the token back (alive during decode)
            let feedbackRC = decode(&one)
            if feedbackRC != 0 {
                // Code 1 mid-stream = context filled while generating THIS reply — graceful stop,
                // not a failure (mirrors llama_generate.h:126-132). A fatal (negative) code with
                // nothing produced yet IS a failure; with partial output already yielded, keep it.
                if feedbackRC != 1 && !yieldedAnyText {
                    continuation.finish(throwing: InferenceError.generationFailed(reason: "llama_decode failed"))
                    return
                }
                break
            }
            cachedTokens.append(next)                       // KV (and our mirror) now also holds this reply token
        }
        continuation.finish()
    }

    /// Two-pass wrapper over `llama_tokenize`.
    nonisolated private func tokenize(text: String, addBOS: Bool) -> [llama_token] {
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
    nonisolated private func tokenToPiece(_ token: llama_token) -> String {
        guard let vocab else { return "" }
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if n < 0 {
            // A negative return is -(required bytes): the 64-byte buffer was too small. Re-run with the
            // exact size so the piece isn't silently dropped (H1).
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        guard n > 0 else { return "" }
        let bytes = buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    #endif
}
