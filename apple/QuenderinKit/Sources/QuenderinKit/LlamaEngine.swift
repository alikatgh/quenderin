import Foundation
import os

// The `llama` module is llama.cpp compiled as a C library (via SwiftPM C target
// or a prebuilt llama.xcframework). It is NOT vendored here — see the wiring
// notes below. Until it is linked, `canImport(llama)` is false and this engine
// fails cleanly so the app keeps building against the seam (and can use the mock).
#if canImport(llama)
import llama
#endif

/// Generation-scoped cancellation ledger — the fix for the stop→resend race (audit S2). The old
/// single shared Bool had two failure modes, both user-visible: (a) a NEW generation reset the
/// flag before the still-running decode observed it, so a Stop followed quickly by a new prompt
/// let the old decode run to maxTokens (a dead Stop button + burned battery); (b) the old
/// stream's late onTermination re-set the flag and killed the WRONG (new) generation — a
/// spuriously empty reply. Each generation mints an id; cancellation marks ids up to a bound; a
/// new generation can never unmark, and a stale termination can never reach past its own id.
/// Pure + Sendable so the policy unit-tests without llama linked. Mirrors Android
/// `ChatModel.activeGeneration`.
struct GenerationCancelLedger: Sendable, Equatable {
    private(set) var current: UInt64 = 0
    private(set) var cancelledThrough: UInt64 = 0

    /// Start a new generation; returns its id.
    mutating func mint() -> UInt64 { current += 1; return current }
    /// Cancel every generation minted so far — never a future one (user Stop, model switch, unload).
    mutating func cancelAll() { cancelledThrough = current }
    /// Cancel one generation and everything before it (that generation's stream terminated).
    mutating func cancel(upTo gen: UInt64) { cancelledThrough = max(cancelledThrough, gen) }
    func isCancelled(_ gen: UInt64) -> Bool { gen <= cancelledThrough }
}

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
    /// The `n_ctx` the loaded context was actually created with (sized from the device budget in
    /// `loadLocked`), or nil when nothing is loaded. Surfaced via `loadedContextTokens()` so the
    /// chat layer trims history to the REAL native window, not a hardcoded 4096 (Q-167 twin).
    private var loadedNCtx: Int?
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
    /// Generation-scoped cancellation (S2 — see GenerationCancelLedger). A cancel marks every
    /// generation minted SO FAR; a new generation mints a fresh id it alone answers for.
    private let cancelState = OSAllocatedUnfairLock(initialState: GenerationCancelLedger())
    #endif

    public init(deviceBudgetGB: Double = 4.0) {
        self.deviceBudgetGB = deviceBudgetGB
    }

    public func loadedModelID() async -> String? { loaded }

    /// The real `n_ctx` of the loaded context — an actor-property read, so it never waits on
    /// `nativeLock` (a decode in flight can't stall the chat layer asking for the window size).
    public func loadedContextTokens() async -> Int? { loadedNCtx }

    public func load(model entry: ModelEntry, at fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw InferenceError.modelFileMissing(path: fileURL.path)
        }
        #if canImport(llama)
        cancelState.withLock { $0.cancelAll() }   // stop any running generation before we free the context
        loaded = nil                              // nothing loaded until the new model succeeds
        loadedNCtx = nil
        loadedNCtx = try loadLocked(entry: entry, path: fileURL.path)
        loaded = entry.id
        #else
        throw InferenceError.loadFailed(
            reason: "llama.cpp is not linked into QuenderinKit yet. Add a `llama` module dependency (see the wiring notes in LlamaEngine.swift), or use MockInferenceEngine in the meantime."
        )
        #endif
    }

    public func unload() async {
        #if canImport(llama)
        cancelState.withLock { $0.cancelAll() }
        unloadLocked()
        #endif
        loaded = nil
        loadedNCtx = nil
    }

    /// Best-effort: interrupt an in-flight `generate` (e.g. a stop button). The switch path
    /// already cancels inside `load()`/`unload()`; this is for explicit user cancellation (M3).
    public nonisolated func requestCancel() {
        #if canImport(llama)
        cancelState.withLock { $0.cancelAll() }
        #endif
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loaded != nil else { throw InferenceError.modelNotLoaded }
        #if canImport(llama)
        // Mint THIS generation's id — never reset a shared flag (S2): the old `= false` here
        // erased a Stop aimed at the still-running previous decode, and the old onTermination's
        // `= true` could kill the NEXT generation. With ids, a cancel reaches exactly the
        // generations minted before it.
        let myGen = cancelState.withLock { $0.mint() }
        return AsyncThrowingStream { continuation in
            // Run the decode OFF the cooperative pool (M2) so a multi-second generation doesn't
            // pin a Swift-concurrency thread; `nativeLock` (acquired inside) keeps it safe.
            DispatchQueue.global(qos: .userInitiated).async {
                self.runGeneration(gen: myGen, prompt: prompt, options: options, into: continuation)
            }
            continuation.onTermination = { _ in self.cancelState.withLock { $0.cancel(upTo: myGen) } }
        }
        #else
        throw InferenceError.loadFailed(reason: "llama.cpp not linked; use MockInferenceEngine.")
        #endif
    }

    /// Chat-structured generation: format the conversation with the model's OWN chat template
    /// (from the GGUF, via `llama_chat_apply_template`) so it answers as an assistant and STOPS at
    /// its end-of-turn token — a flat "User:/Assistant:" transcript makes models ramble
    /// hallucinated turns (caught live on the macOS client). Twin of the Android JNI's
    /// `buildChatPrompt` path, including the no-think close for reasoning models.
    public func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loaded != nil else { throw InferenceError.modelNotLoaded }
        #if canImport(llama)
        let prompt = buildChatPrompt(system: system, history: history)
            ?? flatTranscriptPrompt(system: system, history: history)   // model exposes no template
        return try await generate(prompt: prompt, options: options)
        #else
        throw InferenceError.loadFailed(reason: "llama.cpp not linked; use MockInferenceEngine.")
        #endif
    }

    // MARK: - Real inference (compiled only when llama.cpp is linked)

    #if canImport(llama)
    /// Formats the conversation with the model's embedded chat template (Qwen ChatML, Llama-3
    /// headers, …), returning nil when the GGUF carries none (caller falls back to the flat
    /// transcript). For "thinking" models (template gates `enable_thinking`/`<think>`), an empty
    /// think block is closed right after the assistant turn so replies are direct — Android parity
    /// (default thinking OFF). Reads the model pointer under `nativeLock`.
    nonisolated private func buildChatPrompt(system: String, history: [ChatMessage]) -> String? {
        nativeLock.lock()
        defer { nativeLock.unlock() }
        guard let model, let tmplC = llama_model_chat_template(model, nil) else { return nil }
        let tmpl = String(cString: tmplC)

        // llama_chat_message borrows C strings — strdup them and free after the call.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func dup(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        var msgs: [llama_chat_message] = []
        if !system.isEmpty { msgs.append(llama_chat_message(role: dup("system"), content: dup(system))) }
        for m in history {
            msgs.append(llama_chat_message(role: dup(m.role == .user ? "user" : "assistant"), content: dup(m.text)))
        }
        guard !msgs.isEmpty else { return nil }

        var capacity = msgs.reduce(512) { $0 + (($1.content.map { strlen($0) }) ?? 0) + 64 } * 2
        var buf = [CChar](repeating: 0, count: capacity)
        var n = msgs.withUnsafeBufferPointer { ptr in
            llama_chat_apply_template(tmplC, ptr.baseAddress, msgs.count, true, &buf, Int32(capacity))
        }
        if n > Int32(capacity) {   // buffer too small — grow once and retry (mirrors the JNI)
            capacity = Int(n)
            buf = [CChar](repeating: 0, count: capacity)
            n = msgs.withUnsafeBufferPointer { ptr in
                llama_chat_apply_template(tmplC, ptr.baseAddress, msgs.count, true, &buf, Int32(capacity))
            }
        }
        guard n > 0 else { return nil }
        var result = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)

        // No-think: close an empty <think> block after the assistant turn (Qwen3's
        // enable_thinking=false behaviour); normalize whether the template already opened one.
        if tmpl.contains("enable_thinking") || tmpl.contains("<think>") {
            let lastOpen = result.range(of: "<think>", options: .backwards)
            let lastClose = result.range(of: "</think>", options: .backwards)
            let openUnclosed = lastOpen != nil && (lastClose == nil || lastClose!.lowerBound < lastOpen!.lowerBound)
            result += openUnclosed ? "\n</think>\n\n" : "<think>\n\n</think>\n\n"
        }
        return result
    }

    /// The native load, under `nativeLock` (synchronous → manual lock is allowed here, unlike the
    /// async `load()`). Frees any previous model first (free-before-reassign; C1) and throws on
    /// failure, leaving `model`/`context`/`vocab` nil so the engine reports "not loaded".
    /// Returns the `n_ctx` the context was created with, for `loadedContextTokens()` (the caller
    /// stores it on the actor — this nonisolated helper can't write actor state itself).
    nonisolated private func loadLocked(entry: ModelEntry, path: String) throws -> Int {
        nativeLock.lock()
        defer { nativeLock.unlock() }

        if let c = context { llama_free(c) }
        if let m = model { llama_model_free(m) }
        context = nil
        model = nil
        vocab = nil

        if !backendInitialized { llama_backend_init(); backendInitialized = true }  // once per process (L1)

        var modelParams = llama_model_default_params()
        // Metal offload only when the weights actually fit the app budget. A paged MoE
        // (file > budget, e.g. a 13 GB 35B-A3B on 16 GB) runs CPU-only so the OS page cache
        // streams the routed experts — Metal would wire the whole file into the GPU working
        // set and thrash. Real file size, not the catalog estimate (GpuOffloadPolicy docs).
        let fileSizeBytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let fileSizeGB = Double(fileSizeBytes) / 1_000_000_000.0
        modelParams.n_gpu_layers = GpuOffloadPolicy.nGpuLayers(
            fileSizeGB: fileSizeGB, deviceBudgetGB: deviceBudgetGB)
        // Jetsam guard for this project's target class (memory-tight phones under background
        // pressure): mmap keeps the weights pageable (fast cold start, reclaimable by the OS), and
        // mlock is explicitly OFF — wiring multi-GB of weights resident is exactly what gets the app
        // jetsam-killed when the user switches to music/maps. Pin the safe default so it can't regress.
        // (For the paged-MoE path above, mmap isn't just a guard — it IS the streaming mechanism.)
        modelParams.use_mmap = true
        modelParams.use_mlock = false

        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw InferenceError.loadFailed(reason: "llama_model_load_from_file returned null for \(entry.filename)")
        }

        var ctxParams = llama_context_default_params()
        // Flash Attention EXPLICITLY on AUTO — llama.cpp enables it whenever the model supports it
        // (a real Metal decode win + required for quantized V-cache) and resolves to disabled, not a
        // hard failure, when it can't (ENABLED would abort context init on unsupported archs). The
        // pinned framework's default already IS auto, but that default was `false` in older
        // llama.cpp — pin the behavior instead of trusting a default that has changed before.
        // (LlamaFlashAttentionTests pins the enum contract against framework bumps.)
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        // KV-cache dtype from the headroom after weights: tight phones get a q8_0 cache (~half the
        // per-token memory, near-lossless), which the cache-aware n_ctx then turns into ~2× context.
        let kvCacheType = KVCachePolicy.recommend(appBudgetGB: deviceBudgetGB, modelWeightsGB: entry.ramGB)
        // n_ctx from the real app-memory budget, this model's footprint, AND the cache dtype
        // (footprint-aware M1): a 1B gets a big context, a 7B on the same phone is capped tight.
        let nctx = ContextWindow.recommend(
            appBudgetGB: deviceBudgetGB, modelWeightsGB: entry.ramGB, kvCacheType: kvCacheType)
        ctxParams.n_ctx = UInt32(nctx)
        // NB: in modern llama.cpp a QUANTIZED V-cache requires Flash Attention — with FA auto-on
        // this works wherever the model supports FA; the init-failure fallback below covers the
        // models where AUTO resolves to disabled. (The old "q8_0 is safe without FA" note was wrong
        // for this framework version.)
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

        var ctxOrNil = llama_init_from_model(m, ctxParams)
        if ctxOrNil == nil && kvCacheType == .q8_0 {
            // A quantized V-cache needs Flash Attention; on a model where AUTO resolved to
            // disabled, init fails. Retry with f16 KV (more memory, always valid) rather than
            // failing the whole load on exactly the memory-tight devices that picked q8_0.
            ctxParams.type_k = GGML_TYPE_F16
            ctxParams.type_v = GGML_TYPE_F16
            ctxOrNil = llama_init_from_model(m, ctxParams)
        }
        guard let ctx = ctxOrNil else {
            llama_model_free(m)
            throw InferenceError.loadFailed(reason: "llama_init_from_model returned null")
        }

        model = m
        context = ctx
        vocab = llama_model_get_vocab(m)
        cachedTokens = []   // fresh context ⇒ empty KV cache
        return nctx
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
        gen myGen: UInt64,
        prompt: String,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        // This generation answers ONLY for its own id — a cancel aimed at an older run, or a
        // stale onTermination from a dead stream, can never stop it (S2).
        let cancelled = { self.cancelState.withLock { $0.isCancelled(myGen) } }
        nativeLock.lock()
        defer { nativeLock.unlock() }

        guard let context, vocab != nil else {
            continuation.finish(throwing: InferenceError.modelNotLoaded)
            return
        }

        // 1) Prompt → tokens.
        let rawTokens = tokenize(text: prompt, addBOS: true)
        guard !rawTokens.isEmpty else {
            continuation.finish(throwing: InferenceError.generationFailed(reason: "tokenizer produced no tokens"))
            return
        }
        // 1b) Clamp to the context window. llama.cpp hard-aborts the PROCESS (ggml_abort →
        // SIGABRT) when asked to decode more tokens than the KV cache can seat — a 24 KB PDF
        // attachment tokenizes well past a small n_ctx (App Review-visible crash, 0.2.0(4)).
        // Truncate middle-out: the head keeps the attachment label/lead-in, the tail keeps the
        // user's actual question (the prompt ends with it); the dropped middle is what a context
        // this size could never hold anyway. Reserve headroom so the reply has room to decode.
        let nCtx = Int(llama_n_ctx(context))
        let reserve = max(256, min(options.maxTokens, nCtx / 4))
        let promptLimit = max(16, nCtx - reserve)
        let newTokens: [llama_token]
        if rawTokens.count > promptLimit {
            let head = promptLimit / 2
            newTokens = Array(rawTokens.prefix(head)) + Array(rawTokens.suffix(promptLimit - head))
        } else {
            newTokens = rawTokens
        }

        // 2) Sampler chain from the request options (penalties → top-p → temperature → dist).
        // The repetition penalty is what keeps Q2-class small models from looping the same
        // paragraph verbatim (docs/BUG_JOURNAL.md 2026-07-03). Kotlin twin: jni sampler chain.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        // GBNF-constrained decoding (opt-in): masks every token that can't continue the grammar,
        // so e.g. an agent decision CANNOT be prose. FIRST in the chain — top-p/temperature then
        // renormalize over the legal set only (top-p before grammar could keep only illegal
        // tokens). A grammar string that fails to parse returns NULL — skip it and decode
        // unconstrained (mirrors the desktop's null-grammar fallback) rather than crash.
        if let gbnf = options.gbnfGrammar, let v = vocab {
            if let grammarSampler = llama_sampler_init_grammar(v, gbnf, "root") {
                llama_sampler_chain_add(sampler, grammarSampler)
            }
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
            Int32(options.repeatLastN), Float(options.repeatPenalty), 0, 0))
        // Top-k (opt-in, 0 = off) BEFORE top-p — the standard llama.cpp order, and the agent decode
        // uses it to match Qwen3's `top_k=20` recipe. It runs AFTER the grammar mask, so it only
        // trims already-legal tokens (the free `input` string's tail); it can never starve the JSON.
        if options.topK > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(options.topK)))
        }
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
            // llama.cpp also hard-aborts if ONE llama_decode call carries more tokens than
            // n_batch (2048 default — we never raise it), so a long prefill is fed in
            // n_batch-sized chunks: the standard prompt-processing loop. A within-limit prompt
            // is exactly one chunk ≡ the old single-call behavior, same borrowed-pointer rule.
            let nBatch = max(1, Int(llama_n_batch(context)))
            var start = 0
            while start < toks.count {
                let end = min(start + nBatch, toks.count)
                var chunk = Array(toks[start..<end])
                let rc = chunk.withUnsafeMutableBufferPointer {
                    llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
                }
                if rc != 0 { return rc }
                start = end
            }
            return 0
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
        // A Stop during prefill (before the first token) must land too — the native prefill
        // decode is a single non-interruptible call, so check cancelState right around it and
        // bail before we start a long feedback loop (Q-005/Q-217). A big prompt can spend
        // seconds here; without this check Stop was completely dead until the first token.
        if cancelled() { continuation.finish(); return }
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
        var decoder = UTF8StreamDecoder()   // survives across tokens: split characters reassemble
        // Watches for a stop sequence (e.g. "</think>") that may span tokens; inert when none set,
        // so a plain generation is byte-for-byte unchanged. (Revives the dead stopSequences field.)
        var stopScanner = StopSequenceScanner(stops: options.stopSequences)
        var yieldedAnyText = false   // mirrors llama_generate.h's `out.empty()` — true once ANY non-empty
                                      // piece has been yielded, INCLUDING the current token's (checked
                                      // below only after this token's own yield, same ordering as the
                                      // C++ `out += piece` happening before the fatal check).
        while produced < options.maxTokens {
            if cancelled() { break }   // interrupted by a switch/cancel aimed at THIS generation (M3/S2)
            if produced % thermalSampleInterval == 0,
               let retuned = governor.update(level: ThermalMonitor.currentLevel()) {
                llama_set_n_threads(context, Int32(retuned), Int32(retuned))
            }
            let next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }   // end-of-generation token

            let piece = decoder.feed(tokenToBytes(next))
            if !piece.isEmpty {
                if stopScanner.isActive {
                    let (emit, stop) = stopScanner.feed(piece)
                    if !emit.isEmpty { continuation.yield(emit); yieldedAnyText = true }
                    if stop { break }   // a stop sequence completed — halt here (skip the feedback decode)
                } else {
                    continuation.yield(piece)
                    yieldedAnyText = true
                }
            }
            produced += 1

            var one = [next]                               // feed the token back (alive during decode)
            let feedbackRC = decode(&one)
            if feedbackRC != 0 {
                // Code 1 mid-stream = context filled while generating THIS reply — graceful stop,
                // not a failure (mirrors llama_generate.h:126-132); the KV is full but VALID, so
                // the mirror stays. A fatal (negative) code leaves the KV state UNKNOWN — clear
                // cache and mirror so the next turn re-prefills cleanly instead of reusing a
                // possibly-desynced prefix (audit S3). With partial output already yielded, keep
                // the text; with nothing yielded, it's a failure.
                if feedbackRC != 1 {
                    llama_memory_clear(mem, true)
                    cachedTokens = []
                    if !yieldedAnyText {
                        continuation.finish(throwing: InferenceError.generationFailed(reason: "llama_decode failed"))
                        return
                    }
                }
                break
            }
            cachedTokens.append(next)                       // KV (and our mirror) now also holds this reply token
        }
        let tail = decoder.flush()                          // any held bytes (end-of-stream mid-character)
        if stopScanner.isActive {
            if !tail.isEmpty {
                let (emit, _) = stopScanner.feed(tail)      // a stop sequence may complete on the tail
                if !emit.isEmpty { continuation.yield(emit) }
            }
            let held = stopScanner.flush()                  // no stop matched — release the held-back tail
            if !held.isEmpty { continuation.yield(held) }
        } else if !tail.isEmpty {
            continuation.yield(tail)
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

    /// Wrapper over `llama_token_to_piece` (single token → raw UTF-8 BYTES). Callers must
    /// decode through `UTF8StreamDecoder` — tokens routinely end mid-character (Cyrillic,
    /// emoji), and per-token String decoding turns the halves into "�".
    nonisolated private func tokenToBytes(_ token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if n < 0 {
            // A negative return is -(required bytes): the 64-byte buffer was too small. Re-run with the
            // exact size so the piece isn't silently dropped (H1).
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }
    #endif
}
