package ai.quenderin.core

/**
 * Real on-device engine: a thin Kotlin adapter over llama.cpp, reached through JNI
 * over the NDK. The C++ side (`jni/llama_jni.cpp`) is compiled by the app module's
 * `externalNativeBuild` (CMake) into `libquenderin_llama.so` for each ABI — see
 * `android/INTEGRATION.md`. Twin of Swift `LlamaEngine` (gated behind
 * `#if canImport(llama)`); llama.cpp stays C/C++, this is only the adapter.
 *
 * Crucially, this Kotlin compiles and unit-tests on a plain JVM: `System.loadLibrary`
 * is guarded, so off-device (no `.so`) [available] is `false` and every call fails
 * cleanly with [UNAVAILABLE_MSG] instead of crashing. On a real device build with the
 * `.so` present, [available] flips `true` and calls bridge into llama.cpp. This is the
 * "fails cleanly until linked" contract the tests pin down.
 */
class LlamaEngine(
    /** Device app-memory budget (GB, native-heap); n_ctx is sized from this + the model footprint. */
    private val deviceBudgetGb: Double = 4.0,
    /** Worker threads; 0 → ThreadPlanner picks the big-core count. */
    private val threads: Int = 0,
    private val maxTokens: Int = 512,
    /** Sampling, matched to iOS `GenerationOptions` defaults — top-p + temperature, NOT greedy (which
     *  loops/repeats). `temperature <= 0` falls back to deterministic greedy in the native sampler. */
    private val temperature: Double = 0.7,
    private val topP: Double = 0.95,
    /** Layers to offload to the GPU (llama.cpp `n_gpu_layers`). The app computes this with
     *  [GpuOffloadPlanner] from `Build.SOC_MODEL` + whether the `.so` carries the Vulkan backend; the
     *  core stays `android.os`-free. Default 0 → CPU, so the JVM tests and CPU builds are unchanged. */
    private val gpuLayers: Int = GpuOffloadPlanner.CPU_ONLY,
    /** Synchronous immutable report from this generation owner; never reads another engine's result. */
    private val onPerformance: ((InferencePerformanceSample) -> Unit)? = null,
    /** App hashes nonunique hardware/OS/driver facts together with this bounded execution config. */
    private val performanceEnvironment: (String) -> String = { InferencePerformanceIdentity.fingerprint("host|$it") },
    private val thermalSnapshot: (() -> ThermalLevel)? = null,
    private val artifactReceipts: ModelArtifactVerificationReceipts = ModelArtifactVerificationReceipts.process,
) : InferenceEngine {

    override var loadedModelId: String? = null
        private set

    /**
     * The `n_ctx` the current model was actually loaded with (sized from the device's memory budget +
     * the model footprint at [load]), or null when nothing is loaded. Exposed so the chat history is
     * trimmed to the REAL native window — often 512–2048 on phones — instead of a hardcoded 4096 that
     * would silently overflow it (Q-167). @Volatile: written under [lock] in [load]/[unload], read on the
     * generation thread when the budget is computed.
     */
    @Volatile
    override var loadedContextTokens: Int? = null
        private set

    /** Opaque native pointer (a `llama_context*` on the C++ side); 0 = nothing loaded. */
    private var handle: Long = 0L
    private var loadedMuse = false
    private var loadedJais = false
    private var loadedBeam = false
    private var loadedSpecialist = false
    @Volatile private var loadedArtifactIdentity: String? = null
    private var loadedArtifactReceipt: ModelArtifactVerificationReceipts.Receipt? = null
    @Volatile private var loadedLoadMs = 0.0
    @Volatile private var loadedKVCacheNativeId = 0
    private var generationThermalLevel = ThermalLevel.NOMINAL

    /**
     * Per-send chat decode cap from [ChatTier] (tiny models get 256, full 512). Null → [maxTokens].
     * Written on the UI/send path before [completeChat]; read under [lock] inside generation.
     */
    @Volatile
    var chatMaxTokensOverride: Int? = null

    /**
     * When true, reasoning models (Qwen3, DeepSeek-R1) are allowed to emit their <think> chain before
     * answering — slower but shows the model's reasoning. Default OFF: fast, direct replies (the native
     * side closes an empty think block). Toggled from Settings ("Deep thinking"). @Volatile: read on the
     * generation thread, written from the UI thread.
     */
    @Volatile
    var enableThinking: Boolean = false

    /** The unthrottled (big-core) thread count chosen at load — the governor's baseline for
     *  [recommendedThreads]'s in-flight thermal re-tuning during generation (mirrors iOS
     *  `loadedBaseThreads`). Set under [lock] in [load]; read by the native decode loop via JNI. */
    @Volatile
    private var loadedBaseThreads: Int = 1

    /**
     * Cancellation flag the native decode loop polls each token (`jni/llama_jni.cpp`). `@Volatile`
     * + lock-free on purpose: [requestCancel] must signal a running [complete] WITHOUT taking [lock]
     * (which that generation holds). Reset at the start of each completion. Audit M3.
     */
    @Volatile
    private var cancelRequested: Boolean = false

    /**
     * Completion reason of the most recent generation. Reset to UNKNOWN at every run/load/unload;
     * set only when this run still owns [capRun]. HIT/NOT_HIT are never inferred from piece counts.
     */
    @Volatile
    private var lastCapStatus: ChatCapStatus = ChatCapStatus.UNKNOWN
    private var capRun: Long = 0L


    /**
     * Live thermal pressure, supplied by the app (which reads `PowerManager.currentThermalStatus`
     * via [ThermalMonitor.levelFromStatus]; the core stays free of `android.os`). Read at load to
     * size the thread count — launch while the phone is already hot → start with fewer threads so a
     * long generation stays sustainable. Defaults to NOMINAL, so behaviour is unchanged if unset.
     */
    @Volatile
    var thermalLevel: ThermalLevel = ThermalLevel.NOMINAL

    /**
     * The app's `applicationInfo.nativeLibraryDir` — where Gradle unpacked the ggml CPU-variant
     * backends (`libggml-cpu-android_armv*.so`). Passed to the native side at load so ggml can
     * dlopen the best variant for the LIVE CPU (DOTPROD/I8MM on modern SoCs — the fast matmul
     * kernels a single generic arm64 build never used). Set by the app before [load]; the core
     * stays `android`-free. Empty → the statically-linked default backend (tests, old builds).
     */
    @Volatile
    var nativeLibDir: String = ""

    /**
     * Serializes ALL native access. load/unload/complete must not interleave — a `unload()` on
     * one thread (e.g. UI cancel) while `complete()` runs on another would free the native handle
     * mid-call → use-after-free / SIGSEGV (C2). Held across the long native call on purpose: you
     * cannot safely free during a native generation anyway.
     */
    private val lock = Any()

    /** True only when the native library actually loaded — i.e. a real device build. */
    fun available(): Boolean = NATIVE_AVAILABLE

    /**
     * Called from the native decode loop every ~32 tokens (`jni/llama_generate.h`'s `thermalPoll`)
     * so a long generation sheds threads as the SoC heats, instead of staying pinned at the
     * load-time count for the whole reply — mirrors iOS's in-flight `ThermalGovernor` sampling
     * (`LlamaEngine.swift`'s `runGeneration`). Lock-free/read-only, same as [cancelRequested]'s poll.
     */
    fun recommendedThreads(): Int {
        val current = currentThermal()
        if (current.ordinal > generationThermalLevel.ordinal) generationThermalLevel = current
        return ThermalThrottle.recommendedThreads(current, loadedBaseThreads)
    }
    private fun currentThermal(): ThermalLevel = thermalSnapshot?.invoke() ?: thermalLevel

    /** Same load configuration used by candidate admission; requested offload is never called actual GPU. */
    fun plannedContext(model: ModelEntry): Int {
        val kv = KVCachePolicy.recommend(deviceBudgetGb, model.ramGB)
        val tokens = ContextWindow.recommend(deviceBudgetGb, model.ramGB, kv)
        return when {
            ModelRuntimeSupport.isBeam(model) -> minOf(tokens, 4096)
            ModelRuntimeSupport.isMuse(model) -> minOf(tokens, ModelRuntimeSupport.MUSE_MAX_CONTEXT_TOKENS)
            ModelRuntimeSupport.isBonsai(model) -> minOf(tokens, ModelRuntimeSupport.BONSAI_MAX_CONTEXT_TOKENS)
            else -> tokens
        }
    }
    fun candidateEnvironment(model: ModelEntry, contextTokens: Int = plannedContext(model)): String {
        val base = if (threads > 0) threads else ThreadPlanner.recommend(ThreadPlanner.performanceCoreCount(), Runtime.getRuntime().availableProcessors())
        return environment(contextTokens, KVCachePolicy.recommend(deviceBudgetGb, model.ramGB).nativeId, base)
    }
    override fun automaticExecutionProfiles(model: ModelEntry, request: AutomaticChatRequest?, observations: List<InferencePerformanceSample>): List<AutomaticExecutionProfile> = synchronized(lock) {
        val backend = registeredRuntimeID ?: return emptyList()
        // Updatable Vulkan driver identity is not established by Build.SOC_MODEL or a requested layer count.
        if (!NATIVE_AVAILABLE || !supportsPerformance || gpuLayers != GpuOffloadPlanner.CPU_ONLY || !ModelRuntimeSupport.supports(model)) return emptyList()
        val artifact = InferencePerformanceIdentity.artifact(model) ?: return emptyList()
        if (loadedModelId == model.id) {
            if (loadedArtifactIdentity != artifact) return emptyList()
            val proof = loadedArtifactReceipt ?: return emptyList()
            if (!artifactReceipts.retainLoaded(model, proof)) return emptyList()
            val context = loadedContextTokens ?: return emptyList()
            var cache = "cold"
            var tokens: Int? = null
            if (request != null) {
                val actual = pendingChatConfiguration(model, request, context)
                if (actual.size != 4 || actual[0].toInt() != context || actual[1].toInt() != loadedKVCacheNativeId) return emptyList()
                tokens = actual[2].toInt(); cache = if (actual[3] == 0L) "cold" else "prefix"
            }
            return listOf(AutomaticExecutionProfile(InferencePerformanceRuntime.ID, backend,
                environment(context, loadedKVCacheNativeId, loadedBaseThreads), context, currentThermal(), cache, tokens))
        }
        // Recover ONLY effective configurations actually observed for this artifact/runtime/device.
        // This includes q8->f16/shrunk-window loads; the requested q8 plan is never treated as proof.
        val base = if (threads > 0) threads else ThreadPlanner.recommend(ThreadPlanner.performanceCoreCount(), Runtime.getRuntime().availableProcessors())
        return observations.take(64).filter { it.valid(System.currentTimeMillis()) && it.modelID == model.id &&
            it.artifactSHA256 == artifact && it.runtimeID == InferencePerformanceRuntime.ID && it.backendID == backend && it.cacheMode == "cold" }
            .mapNotNull { sample ->
                val matchesActualKV = (0..1).any { kv -> environment(sample.contextTokens, kv, base) == sample.environmentID }
                if (!matchesActualKV) null else AutomaticExecutionProfile(InferencePerformanceRuntime.ID, backend,
                    sample.environmentID, sample.contextTokens, currentThermal(), "cold")
            }.distinctBy { it.environmentID }
    }
    private fun pendingChatConfiguration(model: ModelEntry, request: AutomaticChatRequest, context: Int): LongArray {
        fun clean(value: String) = value.replace('\u001E', ' ').replace('\u001F', ' ')
        val payload = buildString {
            append("system\u001F${clean(ChatTier.of(model).systemPrompt)}\u001E")
            request.windowedHistory(model, context).forEach { message ->
                append(if (message.role == Role.USER) "user" else "assistant").append('\u001F')
                    .append(clean(message.text)).append('\u001E')
            }
        }
        return nativeChatExecutionProfile(handle, payload, ChatTier.of(model).maxTokens, !enableThinking)
    }
    override fun pendingChatFits(model: ModelEntry, request: AutomaticChatRequest): Boolean = synchronized(lock) {
        if (!NATIVE_AVAILABLE || !supportsPerformance || loadedModelId != model.id || handle == 0L) return false
        val context = loadedContextTokens ?: return false
        val actual = pendingChatConfiguration(model, request, context)
        actual.size == 4 && actual[0] == context.toLong() && actual[2] >= 0 && actual[2] + ChatTier.of(model).maxTokens <= actual[0]
    }
    private fun environment(context: Int, kv: Int, baseThreads: Int): String = performanceEnvironment(
        "ctx=$context;kv=$kv;threads=$baseThreads;gpuLayersRequested=$gpuLayers;temperature=$temperature;topP=$topP;thinking=$enableThinking;batch=512;warmup=1")

    /** Interrupt a running [complete] (the native loop polls [cancelRequested]); lock-free (M3). */
    override fun requestCancel() { cancelRequested = true }
    override fun setChatTokenBudget(tokens: Int) { chatMaxTokensOverride = tokens }
    override fun thinkingEnabled(): Boolean = enableThinking
    override fun setThinkingEnabled(enabled: Boolean) { enableThinking = enabled }

    /**
     * True when the most recent native generation reports a token-budget stop. This is the legacy
     * boolean contract and is intentionally independent of [chatCapStatus]: it can be true even
     * when the new status is UNKNOWN because no trustworthy measured completion was available.
     */
    override fun lastHitTokenCap(): Boolean = synchronized(lock) {
        if (!NATIVE_AVAILABLE || handle == 0L) false else nativeLastHitTokenCap(handle)
    }

    override fun chatCapStatus(): ChatCapStatus = lastCapStatus
    override fun load(model: ModelEntry, filePath: String) = synchronized(lock) {
        capRun++
        lastCapStatus = ChatCapStatus.UNKNOWN
        val loadStarted = System.nanoTime()
        ModelArtifacts.validate(model)
        check(ModelRuntimeSupport.supports(model)) { ModelRuntimeSupport.unavailableMessage(model) }
        if (ModelRuntimeSupport.requiresMemoryGate(model)) {
            val fitness = MemoryFitness.check(model, deviceBudgetGb, deviceBudgetGb)
            check(fitness.canLoad) { fitness.message }
        }
        check(NATIVE_AVAILABLE) { UNAVAILABLE_MSG }
        ModelRuntimeSupport.metadataUnavailableReason(filePath, model)?.let { throw IllegalStateException(it) }
        cancelRequested = false
        // Unknown publisher hashes remain usable manually but can never become measured evidence.
        val artifactIdentity = InferencePerformanceIdentity.artifact(model)
        val reusedReceipt = artifactIdentity?.let { artifactReceipts.current(model, filePath) }
        val receipt = artifactIdentity?.let { checkNotNull(artifactReceipts.verify(model, filePath)) { "Model artifact verification failed." } }
        if (model.artifacts.isNotEmpty() && artifactIdentity == null) ModelArtifacts.requireComplete(model, filePath) { cancelRequested }
        loadedArtifactIdentity = null
        if (handle != 0L) { nativeFree(handle); handle = 0L; loadedModelId = null; loadedMuse = false; loadedContextTokens = null }
        // Performance (big) cores, not all cores — LITTLE cores slow + heat up mobile decode.
        val base = if (threads > 0) threads
        else ThreadPlanner.recommend(ThreadPlanner.performanceCoreCount(), Runtime.getRuntime().availableProcessors())
        loadedBaseThreads = base   // governor baseline for in-flight thermal re-tuning (recommendedThreads)
        // If the device is already thermally throttling, start with fewer threads (heat is the
        // sustained-load ceiling on a phone, not memory).
        val t = ThermalThrottle.recommendedThreads(currentThermal(), base)
        // KV-cache dtype from the headroom after weights: tight phones get a q8_0 cache (~half the
        // per-token memory, near-lossless), which the cache-aware n_ctx turns into ~2× context.
        val kvCacheType = KVCachePolicy.recommend(deviceBudgetGb, model.ramGB)
        // n_ctx from the real app-memory budget, this model's footprint, AND the cache dtype (M1).
        val nctx = ContextWindow.recommend(deviceBudgetGb, model.ramGB, kvCacheType).let {
            when {
                ModelRuntimeSupport.isBeam(model) -> minOf(it, 4096)
                ModelRuntimeSupport.isMuse(model) -> minOf(it, ModelRuntimeSupport.MUSE_MAX_CONTEXT_TOKENS)
                ModelRuntimeSupport.isBonsai(model) -> minOf(it, ModelRuntimeSupport.BONSAI_MAX_CONTEXT_TOKENS)
                else -> it
            }
        }
        if (ModelRuntimeSupport.isBeam(model)) {
            val free = minOf(deviceBudgetGb, NativeModelResources.availableMemoryBytes().toDouble() / (1024.0 * 1024 * 1024))
            check(MemoryFitness.check(model, deviceBudgetGb, free).canLoad) { ModelRuntimeSupport.BEAM_UNAVAILABLE_MESSAGE }
        }
        handle = nativeLoad(filePath, nctx, t, kvCacheType.nativeId, temperature.toFloat(), topP.toFloat(), gpuLayers,
            nativeLibDir, verifiedMuse = ModelRuntimeSupport.isVerifiedMuseManifest(model), verifiedBeam = ModelRuntimeSupport.isVerifiedBeamManifest(model), verifiedHy = false, verifiedGranite = false)
        if (handle == 0L) throw IllegalStateException("llama.cpp could not load ${model.filename}")
        if (receipt != null && artifactReceipts.current(model, filePath) != receipt) {
            nativeFree(handle); handle = 0L; throw IllegalStateException("Model artifact changed during loading.")
        }
        // A preflight hash occurred before this load() call. Include its observed cost once rather
        // than publishing native-only load timing after the caller already paid a multi-GB scan.
        loadedLoadMs = (System.nanoTime() - loadStarted) / 1_000_000.0 + (reusedReceipt?.verificationMs ?: 0.0)
        loadedArtifactIdentity = artifactIdentity
        loadedArtifactReceipt = receipt
        loadedKVCacheNativeId = if (supportsPerformance) nativeLoadedKVCache(handle) else kvCacheType.nativeId
        loadedModelId = model.id
        loadedMuse = ModelRuntimeSupport.isMuse(model)
        loadedJais = nativeIsJais(handle) || ModelRuntimeSupport.isJais(model)
        loadedBeam = ModelRuntimeSupport.isBeam(model)
        // JNI may shrink n_ctx on the q8_0→F16 KV-cache fallback; publish the window that
        // actually exists, not the q8-sized request (otherwise ChatModel trims to a window
        // larger than native and overflows — twin of the Aug-10 llama_jni.cpp n_ctx resize).
        val actual = nativeLoadedNCtx(handle)
        loadedContextTokens = if (actual > 0) actual else nctx
    }

    override fun unload() = synchronized(lock) {
        capRun++
        lastCapStatus = ChatCapStatus.UNKNOWN
        if (handle != 0L) {
            nativeFree(handle)
            handle = 0L
        }
        loadedModelId = null
        loadedMuse = false
        loadedJais = false
        loadedBeam = false
        loadedSpecialist = false
        loadedContextTokens = null
        loadedArtifactIdentity = null
        loadedArtifactReceipt = null
    }

    override fun complete(prompt: String): String = synchronized(lock) {
        capRun++
        lastCapStatus = ChatCapStatus.UNKNOWN
        ensureReady()
        check(!loadedMuse && !loadedJais && !loadedBeam && !loadedSpecialist) { "This experimental model supports text chat only. Choose another model for agent actions." }
        cancelRequested = false   // fresh generation (M3)
        nativeComplete(handle, prompt, maxTokens)
    }

    /** Grammar-constrained decode (the agent decision) — a per-call GBNF-masked sampler in the JNI, so
     *  the decision can't be prose. Parity with the iOS engine's grammar-constrained agent decode. */
    override fun completeWithGrammar(
        prompt: String, grammar: String, maxTokens: Int,
        topP: Float, topK: Int, temperature: Float, repeatPenalty: Float, repeatLastN: Int,
    ): String = synchronized(lock) {
        capRun++
        lastCapStatus = ChatCapStatus.UNKNOWN
        ensureReady()
        check(!loadedMuse && !loadedJais && !loadedBeam && !loadedSpecialist) { "This experimental model supports text chat only. Choose another model for agent actions." }
        cancelRequested = false   // fresh generation (M3)
        nativeCompleteWithGrammar(handle, prompt, maxTokens, grammar, topP, topK, temperature, repeatPenalty, repeatLastN)
    }

    /** The deliberation reasoning decode — unconstrained (the load-time sampler), hard-capped so the
     *  reasoning can't starve the grammar-forced decision that follows. Reuses [nativeComplete] with a
     *  per-call token cap; the grammar decode is a separate call. */
    override fun completeThinking(prompt: String, maxTokens: Int): String = synchronized(lock) {
        capRun++
        lastCapStatus = ChatCapStatus.UNKNOWN
        ensureReady()
        check(!loadedMuse && !loadedJais && !loadedBeam && !loadedSpecialist) { "This experimental model supports text chat only. Choose another model for agent actions." }
        cancelRequested = false   // fresh generation (M3)
        nativeComplete(handle, prompt, maxTokens)
    }

    /**
     * Streaming completion: the native side invokes [onToken] per decoded piece and
     * also returns the full text. Lets the Compose layer render tokens as they arrive.
     */
    override fun complete(prompt: String, onToken: (String) -> Unit): String = synchronized(lock) {
        capRun++
        lastCapStatus = ChatCapStatus.UNKNOWN
        ensureReady()
        check(!loadedMuse && !loadedJais && !loadedBeam && !loadedSpecialist) { "This experimental model supports text chat only. Choose another model for agent actions." }
        cancelRequested = false   // fresh generation (M3)
        nativeCompleteStreaming(handle, prompt, maxTokens, TokenSink { onToken(it) })
    }

    /**
     * Chat-templated streaming completion: the native side formats the structured conversation with the
     * MODEL'S OWN chat template (from the GGUF) so it answers as an assistant and stops at its end-of-turn
     * token — instead of the raw "User:/Assistant:" prompt that made it run to `maxTokens` every reply
     * (the multi-second slowness). Serialize to a role\u001Ftext\u001E payload the JNI parses. Control
     * separators are stripped from text so a stray one can't corrupt the framing.
     */
    override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String =
        completeChatOwned(systemPrompt, history, { true }, onToken)

    override fun completeChatOwned(systemPrompt: String, history: List<ChatMessage>, isCurrent: () -> Boolean, onToken: (String) -> Unit): String =
        synchronized(lock) {
            val myCapRun = ++capRun
            lastCapStatus = ChatCapStatus.UNKNOWN
            ensureReady()
            check(!loadedSpecialist) { "Hy-Memory requires its specialist proposal workflow." }
            if (!isCurrent()) return ""
            cancelRequested = false
            if (!isCurrent()) { cancelRequested = true; return "" }
            fun clean(s: String) = s.replace('\u001E', ' ').replace('\u001F', ' ')
            val payload = buildString {
                if (systemPrompt.isNotEmpty()) append("system").append('\u001F').append(clean(systemPrompt)).append('\u001E')
                history.forEach { m ->
                    append(if (m.role == Role.USER) "user" else "assistant")
                        .append('\u001F').append(clean(m.text)).append('\u001E')
                }
            }
            val cap = chatMaxTokensOverride ?: maxTokens
            // Capture all identities at generation start while the same native-owner lock is held.
            val modelID = loadedModelId
            val artifact = loadedArtifactIdentity
            val context = loadedContextTokens
            val backend = registeredRuntimeID
            val env = context?.let { environment(it, loadedKVCacheNativeId, loadedBaseThreads) }
            generationThermalLevel = currentThermal()
            var report: InferencePerformanceSample? = null
            var measuredStatus: Int? = null
            fun generate(disableThinking: Boolean, sink: TokenSink): String {
                if (onPerformance == null || !supportsPerformance || artifact == null || modelID == null || context == null || env == null || backend == null) {
                    return nativeCompleteChatStreaming(handle, payload, cap, disableThinking, sink)
                }
                return nativeCompleteChatMeasured(handle, payload, cap, disableThinking, sink,
                    PerformanceSink { prompt, prefill, decoded, prefillMs, decodeMs, firstMs, gapMs, cache, status ->
                        measuredStatus = status
                        if (status == 0 && !cancelRequested) report = InferencePerformanceSample(
                            modelID, artifact, InferencePerformanceRuntime.ID, backend, env, context,
                            prompt, prefill, decoded, prefillMs, decodeMs, firstMs, gapMs, loadedLoadMs,
                            if (cache == 0) "cold" else "prefix", generationThermalLevel.name.lowercase(), System.currentTimeMillis())
                    })
            }
            val result =
            if (loadedBeam) {
                val filter = BeamOutputFilter(onToken)
                val wire = try {
                    generate(true, TokenSink { filter.accept(it) })
                } finally { filter.finish() }
                val final = BeamOutputFilter.finalText(wire)
                check(final.isNotEmpty() || cancelRequested) { "Beam generation ended before a final-channel answer." }
                final
            } else if (loadedMuse) {
                val filter = MuseOutputFilter(onToken)
                val wire = try {
                    generate(!enableThinking, TokenSink { filter.accept(it) })
                } finally { filter.finish() }
                MuseOutputFilter.finalText(wire)
            } else if (loadedJais) {
                val filter = JaisOutputFilter(onToken)
                val wire = try {
                    generate(!enableThinking, TokenSink { filter.accept(it) })
                } finally { filter.finish() }
                val final = JaisOutputFilter.finalText(wire)
                check(final.isNotEmpty() || cancelRequested) { "Jais reached its generation limit before producing a final answer. Try a shorter question or a larger token budget." }
                final
            } else {
                generate(!enableThinking, TokenSink { onToken(it) })
            }
            // Filtering/validation above must finish successfully before the evidence leaves the engine.
            if (myCapRun == capRun) {
                val observed = NATIVE_AVAILABLE && handle != 0L
                val nativeHit = if (observed) runCatching { nativeLastHitTokenCap(handle) }.getOrNull() else null
                lastCapStatus = capStatusFor(
                    nativeHit = nativeHit == true,
                    cancelled = cancelRequested,
                    observed = nativeHit != null,
                    measuredStatus = measuredStatus,
                )
            }
            val endingThermal = currentThermal()
            if (endingThermal.ordinal > generationThermalLevel.ordinal) generationThermalLevel = endingThermal
            if (!cancelRequested && result.isNotEmpty()) report?.copy(thermalState = generationThermalLevel.name.lowercase())
                ?.takeIf { it.valid(System.currentTimeMillis()) }?.let { sample ->
                runCatching { onPerformance?.invoke(sample) } // evidence persistence can never fail a chat
            }
            result
        }

    /** Separate engine only: the installer proof is never reconstructed from UI input. */
    internal fun completeHyMemory(request: HyMemoryInferenceRequest, availableMemoryBytes: () -> Long, cancelled: () -> Boolean, onToken: (String) -> Unit): String = synchronized(lock) {
        check(handle == 0L && loadedModelId == null) { "A separate specialist engine is required." }
        check(NATIVE_AVAILABLE && supportsBonsaiRuntime) { UNAVAILABLE_MSG }
        request.artifact.assertCurrent()
        check(availableMemoryBytes() >= HyMemory.MINIMUM_MEMORY_BYTES) { "Hy-Memory requires 32 GiB of available app memory." }
        check(ModelRuntimeSupport.hyMemoryMetadataMatches(request.artifact.filePath)) { "Invalid specialist architecture." }
        require(request.prompt.toByteArray(Charsets.UTF_8).size <= 16_384 && request.prompt.startsWith("<｜hy_begin▁of▁sentence｜>")
            && request.prompt.split("<｜hy_begin▁of▁sentence｜>").size == 2) { "Invalid specialist prompt." }
        cancelRequested = false
        check(!cancelled()) { "Specialist generation cancelled." }
        loadedBaseThreads = minOf(8, maxOf(1, Runtime.getRuntime().availableProcessors()))
        try {
            request.artifact.assertCurrent()
            check(availableMemoryBytes() >= HyMemory.MINIMUM_MEMORY_BYTES) { "Insufficient current memory for the specialist." }
            handle = nativeLoad(request.artifact.filePath, 4096, loadedBaseThreads, 0, 0f, 1f, 0,
                nativeLibDir, verifiedMuse = false, verifiedBeam = false, verifiedHy = true, verifiedGranite = false)
            check(handle != 0L && !cancelRequested && !cancelled()) { "Specialist loading failed or was cancelled." }
            request.artifact.assertCurrent()
            loadedSpecialist = true; loadedModelId = HyMemory.MODEL_ID; loadedContextTokens = nativeLoadedNCtx(handle)
            val result = nativeCompleteHyMemoryStreaming(handle, request.prompt, TokenSink { onToken(it) })
            check(!cancelRequested) { "Specialist generation cancelled." }
            request.artifact.assertCurrent()
            result
        } finally { unload() }
    }

    internal fun completeGranite(proof: GraniteArtifactProof, messages: List<GraniteMessage>, availableMemoryBytes: () -> Long, cancelled: () -> Boolean): String = synchronized(lock) {
        check(handle == 0L && loadedModelId == null && NATIVE_AVAILABLE && supportsBonsaiRuntime && supportsWeeklyTextRuntime) { "The verified Prism text runtime and a separate specialist engine are required." }
        proof.assertCurrent(); check(availableMemoryBytes() >= Granite41.requiredMemory(proof.bytes)) { "Granite requires at least 32 GiB available app memory and whole-model headroom." }
        check(ModelRuntimeSupport.graniteMetadataMatches(proof.filePath)) { "Invalid Granite 4.1 8B metadata." }
        val prompt = Granite41.prompt(messages)
        cancelRequested = false; check(!cancelled()) { "Granite cancelled." }
        loadedBaseThreads = minOf(8, maxOf(1, Runtime.getRuntime().availableProcessors()))
        try {
            proof.assertCurrent()
            handle = nativeLoad(proof.filePath, 4096, loadedBaseThreads, 0, 0.7f, 0.95f, 0, nativeLibDir,
                verifiedMuse = false, verifiedBeam = false, verifiedHy = false, verifiedGranite = true)
            check(handle != 0L && !cancelRequested && !cancelled()) { "Granite loading failed or was cancelled." }
            proof.assertCurrent(); loadedSpecialist = true; loadedModelId = "granite-switch-4.1-8b-local"; loadedContextTokens = nativeLoadedNCtx(handle)
            val output = StringBuilder()
            nativeCompleteHyMemoryStreaming(handle, prompt, TokenSink { piece ->
                output.append(piece); check(output.toString().toByteArray(Charsets.UTF_8).size <= 65_536) { "Granite output exceeded its bound." }
            })
            check(!cancelRequested && !cancelled()) { "Granite cancelled." }; proof.assertCurrent()
            Granite41.finalAnswer(output.toString())
        } finally { unload() }
    }

    private fun ensureReady() {
        if (!NATIVE_AVAILABLE) throw IllegalStateException(UNAVAILABLE_MSG)
        if (handle == 0L || loadedModelId == null) throw EngineNotLoadedException()
    }

    // --- JNI bridge — implemented in jni/llama_jni.cpp, resolved only when called ---
    private external fun nativeLoad(modelPath: String, contextTokens: Int, threads: Int, kvCacheQuant: Int, temperature: Float, topP: Float, gpuLayers: Int, nativeLibDir: String, verifiedMuse: Boolean, verifiedBeam: Boolean, verifiedHy: Boolean, verifiedGranite: Boolean): Long
    private external fun nativeCompleteHyMemoryStreaming(handle: Long, prompt: String, sink: TokenSink): String
    private external fun nativeComplete(handle: Long, prompt: String, maxTokens: Int): String
    private external fun nativeCompleteWithGrammar(handle: Long, prompt: String, maxTokens: Int, grammar: String, topP: Float, topK: Int, temperature: Float, repeatPenalty: Float, repeatLastN: Int): String
    private external fun nativeCompleteStreaming(handle: Long, prompt: String, maxTokens: Int, sink: TokenSink): String
    private external fun nativeCompleteChatStreaming(handle: Long, payload: String, maxTokens: Int, disableThinking: Boolean, sink: TokenSink): String
    private external fun nativeCompleteChatMeasured(handle: Long, payload: String, maxTokens: Int, disableThinking: Boolean, sink: TokenSink, performance: PerformanceSink): String
    private external fun nativeLoadedKVCache(handle: Long): Int
    private external fun nativeChatExecutionProfile(handle: Long, payload: String, maxTokens: Int, disableThinking: Boolean): LongArray
    private external fun nativeLastHitTokenCap(handle: Long): Boolean
    private external fun nativeLoadedNCtx(handle: Long): Int
    private external fun nativeIsJais(handle: Long): Boolean
    private external fun nativeFree(handle: Long)

    /** JNI-friendly callback (a single known method signature `(Ljava/lang/String;)V`). */
    fun interface TokenSink {
        fun onToken(piece: String)
    }

    /** Kept by R8: JNI descriptor (IIIDDDDII)V. No text or prompt enters this sink. */
    fun interface PerformanceSink {
        fun onMetrics(promptTokens: Int, prefillTokens: Int, decodedTokens: Int, prefillMs: Double, decodeMs: Double,
                      firstTokenMs: Double, maxGapMs: Double, cacheMode: Int, status: Int)
    }

    companion object {
        /**
         * Map the pinned native measured completion to the public contract. Only a measured status
         * 0 is a clean completion, where the native budget flag is trustworthy. Status 3 is known
         * context exhaustion (NOT_HIT, not budget); 1/2/4/5 (cancel/fatal/emit/clamp) and a missing
         * measured status (performance not collected) are UNKNOWN. The JNI ABI cannot split EOG
         * from a clean non-budget stop beyond the budget flag; both are NOT_HIT.
         */
        internal fun capStatusFor(
            nativeHit: Boolean,
            cancelled: Boolean,
            observed: Boolean,
            measuredStatus: Int?,
        ): ChatCapStatus =
            when {
                !observed || cancelled -> ChatCapStatus.UNKNOWN
                measuredStatus == null -> ChatCapStatus.UNKNOWN
                measuredStatus == 3 -> ChatCapStatus.NOT_HIT
                measuredStatus != 0 -> ChatCapStatus.UNKNOWN
                nativeHit -> ChatCapStatus.HIT
                else -> ChatCapStatus.NOT_HIT
            }

        @JvmStatic private external fun nativeSupportsPerformance(): Boolean
        @JvmStatic private external fun nativeRegisteredRuntime(): String
        val supportsPerformance: Boolean by lazy { NATIVE_AVAILABLE && runCatching { nativeSupportsPerformance() }.getOrDefault(false) }
        val registeredRuntimeID: String? by lazy {
            if (!supportsPerformance) null else runCatching { nativeRegisteredRuntime() }.getOrNull()
                ?.takeIf { it in InferencePerformanceIdentity.REGISTERED_BACKENDS }
        }
        const val UNAVAILABLE_MSG: String =
            "Native llama.cpp is not linked: build jni/ for this ABI (see android/INTEGRATION.md). " +
                "Use MockInferenceEngine until then."
        const val MUSE_CHAT_ONLY_MESSAGE = "Muse Spark currently supports text chat only. Agent reasoning, raw completion and grammar-constrained tools are unavailable for this experimental model."

        /**
         * Attempts to load `libquenderin_llama.so` once. On the JVM / off-device this
         * throws [UnsatisfiedLinkError], which we swallow so the class stays usable and
         * the seam degrades to a clear error rather than a crash.
         */
        @JvmStatic
        private external fun nativeSupportsBonsai(): Boolean
        @JvmStatic
        private external fun nativeSupportsMuse(): Boolean
        @JvmStatic
        private external fun nativeSupportsWeeklyText(): Boolean
        @JvmStatic
        private external fun nativeSupportsBeam(): Boolean

        /** An old library can load successfully while lacking this symbol. That is unsupported. */
        val supportsBonsaiRuntime: Boolean by lazy {
            NATIVE_AVAILABLE && runCatching { nativeSupportsBonsai() }.getOrDefault(false)
        }
        val supportsMuseRuntime: Boolean by lazy {
            NATIVE_AVAILABLE && runCatching { nativeSupportsMuse() }.getOrDefault(false)
        }
        val supportsBeamRuntime: Boolean by lazy {
            NATIVE_AVAILABLE && runCatching { nativeSupportsBeam() }.getOrDefault(false)
        }
        val supportsWeeklyTextRuntime: Boolean by lazy {
            NATIVE_AVAILABLE && runCatching { nativeSupportsWeeklyText() }.getOrDefault(false)
        }

        val NATIVE_AVAILABLE: Boolean = try {
            System.loadLibrary("quenderin_llama")
            true
        } catch (t: Throwable) {
            false
        }
    }
}
