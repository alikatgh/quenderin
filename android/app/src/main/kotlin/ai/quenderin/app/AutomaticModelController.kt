package ai.quenderin.app

import ai.quenderin.core.*
import java.io.File

/** First ordinary turn only. Integrity receipts and history stay local; no installer/network seam. */
class AutomaticModelController(
    private val engine: InferenceEngine,
    private val onboarding: OnboardingModel,
    private val mode: AutomaticSelectionMode,
    private val store: InferencePerformanceStore,
    private val modelsDir: File,
    private val device: () -> AndroidDeviceProfile,
    private val executionProfiles: (ModelEntry, AutomaticChatRequest?, List<InferencePerformanceSample>) -> List<AutomaticExecutionProfile>,
    private val rememberManualModel: (String) -> Unit = {},
    private val receipts: ModelArtifactVerificationReceipts = ModelArtifactVerificationReceipts.process,
    private val now: () -> Long = System::currentTimeMillis,
    private val onManualStateChanged: () -> Unit = {},
) {
    private val selector = AutomaticTurnSelection(mode, now)
    private data class Label(val modelID: String, val environmentID: String, val observed: Boolean)
    @Volatile private var label: Label? = null
    @Volatile private var pendingManual: ManualModelIntent? = null
    @Volatile private var confirmedManualModelID: String? = null
    @Volatile private var manualError: String? = null
    val manualPreparationMessage: String? get() = pendingManual?.let { "Confirming ${it.model.label}… Your draft is kept." } ?: manualError
    val description: String get() {
        val current = engine.loadedModelId?.let(ModelCatalog::entry) ?: return "Estimated speed · no local model loaded"
        val profile = executionProfiles(current, null, emptyList()).singleOrNull()
        val evidence = label?.takeIf { mode.enabled() && profile != null && it.modelID == current.id && it.environmentID == profile.environmentID && profile.thermalState == ThermalLevel.NOMINAL }
        val runtime = profile?.let { " · ${it.backendID} runtime" } ?: ""
        return "${current.label}$runtime · ${if (evidence?.observed == true) "Observed" else "Estimated"} speed" +
            if (profile == null && mode.enabled()) " · Automatic measurements unavailable for this execution configuration" else ""
    }

    /** Called synchronously by every explicit picker/preset gesture, including an already-current pick. */
    @Synchronized fun manualChoice(model: ModelEntry): ManualModelIntent {
        mode.manualChoice(); rememberManualModel(model.id); label = null; manualError = null
        return ManualModelIntent(model, mode.revisionToken()).also { pendingManual = it; onManualStateChanged() }
    }
    /** Serialized behind an awaiting Automatic load/recovery, even when the transient loaded ID matches. */
    fun confirmManualChoice(model: ModelEntry) { pendingManual?.takeIf { it.model.id == model.id }?.let(::confirmManualChoice) }
    fun confirmManualChoice(intent: ManualModelIntent) {
        if (pendingManual != intent || !mode.currentRevision(intent.revision)) return
        try { onboarding.acceptAndPrepare(intent.model) }
        finally {
            synchronized(this) {
                if (pendingManual == intent && mode.currentRevision(intent.revision)) {
                    val actualID = engine.loadedModelId
                    confirmedManualModelID = actualID; pendingManual = null
                    manualError = if (actualID == intent.model.id) null else {
                        val actual = actualID?.let(ModelCatalog::entry)?.label
                        "Couldn't load ${intent.model.label}. " + if (actual == null) "Choose a local model to continue. Your draft is kept."
                            else "$actual remains selected. Select ${intent.model.label} again to retry."
                    }
                }
            }
            onManualStateChanged()
        }
    }
    @Synchronized fun captureTurnIntent(): LocalTurnIntent = LocalTurnIntent(mode.revisionToken(),
        if (mode.enabled()) null else confirmedManualModelID ?: engine.loadedModelId, pendingManual == null)
    @Synchronized fun acceptsTurnIntent(intent: LocalTurnIntent): Boolean = intent.ready && pendingManual == null &&
        mode.currentRevision(intent.revision) && (intent.requiredManualModelID == null || engine.loadedModelId == intent.requiredManualModelID)
    fun setAutomaticEnabled(enabled: Boolean) {
        if (pendingManual != null) return
        mode.setEnabled(enabled); label = null; manualError = null
        if (!enabled) engine.loadedModelId?.let { confirmedManualModelID = it; rememberManualModel(it) }
    }

    /** One preparation path for Send, starters and Continue, with the gesture's captured intent. */
    fun prepareTurn(request: AutomaticChatRequest, firstOrdinaryTurn: Boolean, hasDocuments: Boolean, pinnedID: String?,
                    intent: LocalTurnIntent, isCurrent: () -> Boolean): PreparedLocalTurn? {
        check(onboarding.phase is OnboardingPhase.Ready) { "The selected local model is still being prepared. Your draft is kept." }
        check(acceptsTurnIntent(intent)) { "The requested local model is still being confirmed. Your draft is kept." }
        val stillCurrent = { isCurrent() && acceptsTurnIntent(intent) }
        val selected = if (mode.enabled() && !firstOrdinaryTurn && pinnedID != null) restorePinned(pinnedID, request, stillCurrent)
            else prepare(request.text, firstOrdinaryTurn, hasDocuments, request, stillCurrent)
        return selected?.let { model -> PreparedLocalTurn(model) { stillCurrent() && engine.loadedModelId == model.id } }
    }

    fun prepare(prompt: String, firstTurn: Boolean, hasDocuments: Boolean, request: AutomaticChatRequest = AutomaticChatRequest(prompt), isCurrent: () -> Boolean = { true }): ModelEntry? {
        label = null // No early return can retain another turn/model/profile's observed label.
        check(pendingManual == null) { "Confirming the requested local model. Your draft is kept." }
        val current = engine.loadedModelId?.let(ModelCatalog::entry) ?: return null
        if (!mode.enabled() || !firstTurn || hasDocuments || !engine.automaticSelectionIdle) return current
        val ticket = mode.ticket() ?: return current
        val samples = store.samples()
        val execution = executionProfiles(current, request, samples).singleOrNull() ?: return current
        if (execution.thermalState != ThermalLevel.NOMINAL) return current
        val facts = device()
        val task = ModelRouter.classify(prompt)
        val installed = ModelManager(FileModelStorage(modelsDir), current.id).installed().map { it.model }
        val tokens = execution.promptTokens ?: ConversationContext.estimateTokens(ChatTier.of(current).systemPrompt + "\nUser: " + prompt + "\nAssistant:")
        val profiles = HashMap<String, AutomaticExecutionProfile>()
        val preliminary = installed.flatMap { model ->
            val artifact = InferencePerformanceIdentity.artifact(model) ?: return@flatMap emptyList()
            val possibilities = if (model.id == current.id) listOf(execution) else executionProfiles(model, null, samples)
            possibilities.map { profile ->
                profiles[profile.environmentID + "|" + model.id] = profile
                val ordinary = model.id in AndroidModelSelector.defaultPreferenceIds ||
                    (task == TaskKind.CODING && model.id.startsWith("qwen25-coder")) ||
                    (task == TaskKind.REASONING && model.id.startsWith("deepseek-r1")) || model.id == current.id
                val quality = ChatTier.of(model).ordinal >= ChatTier.of(current).ordinal &&
                    (Quantization.info(model.quantization)?.bitsPerWeight ?: 0.0) >= (Quantization.info(current.quantization)?.bitsPerWeight ?: 0.0)
                // A verified working current allocation is not charged a second time by a fresh-load estimate.
                val memory = model.id == current.id || AndroidModelSelector.estimatedRuntimeGb(model, profile.contextTokens) <= facts.appMemoryBudgetGb * AndroidModelSelector.MEMORY_HEADROOM
                val context = tokens + ChatTier.of(model).maxTokens <= profile.contextTokens
                val path = File(modelsDir, model.filename).absolutePath
                val proof = receipts.current(model, path)
                // Conservative cold-verification floor before deciding to read GB of weights. Once a
                // receipt exists, retain its observed verification cost as a conservative switch debit.
                val verificationFloor = proof?.verificationMs ?: ((model.downloadBytes ?: File(path).length()).coerceAtLeast(0) / 25_000.0)
                AutomaticModelCandidate(model.id, artifact, profile.runtimeID, profile.backendID, profile.environmentID,
                    true, model.id == current.id || proof != null, ModelRuntimeSupport.supports(model), memory, context,
                    facts.freeDiskGb >= 0, ordinary, quality, verificationFloor, profile.cacheMode, profile.contextTokens)
            }
        }
        // Choose the task family AFTER runtime, memory, context and quality admission.
        val familyPool = preliminary.filter { it.installed && it.runtimeAvailable && it.fitsMemory && it.fitsContext && it.fitsDisk && it.qualityEligible && it.supportsTask }
        val familyRank = familyPool.mapNotNull { c -> ModelCatalog.entry(c.modelID)?.let { ModelRouter.familyRank(it, task) } }.minOrNull()
        val candidates = preliminary.map { c -> c.copy(supportsTask = c.supportsTask &&
            (c.modelID == current.id || ModelCatalog.entry(c.modelID)?.let { ModelRouter.familyRank(it, task) == familyRank } == true)) }
        val projected = MeasuredAutomaticPolicy.choose(current.id, candidates.map { it.copy(verified = true) }, samples,
            tokens, ChatTier.of(current).maxTokens, execution.contextTokens, execution.cacheMode, now())
        val alternative = projected?.modelID?.takeIf { it != current.id }?.let(ModelCatalog::entry)
        val verified = alternative?.takeIf { mode.current(ticket) && isCurrent() && verifiedPath(it) != null }
        val admitted = candidates.map { candidate ->
            val proof = if (verified != null && candidate.modelID == verified.id) receipts.current(verified, File(modelsDir, verified.filename).absolutePath) else null
            candidate.copy(verified = candidate.verified || (proof != null && candidate.environmentID == projected?.environmentID),
                switchCostFloorMs = maxOf(candidate.switchCostFloorMs, proof?.verificationMs ?: 0.0))
        }
        val decision = selector.prepare(firstTurn, current.id, admitted, samples, tokens,
            ChatTier.of(current).maxTokens, execution.contextTokens, execution.cacheMode, isCurrent = isCurrent) { id, stillCurrent ->
            val selected = admitted.firstOrNull { it.modelID == id && it.environmentID == projected?.environmentID }
            val expected = selected?.let { profiles[it.environmentID + "|" + id] }
            ModelCatalog.entry(id)?.let { onboarding.activateInstalled(it, expectedProfile = expected, request = request, isCurrent = stillCurrent) } ?: false
        }
        if (!mode.current(ticket)) throw AutomaticSelectionChangedException()
        val loaded = engine.loadedModelId?.let(ModelCatalog::entry)
        check(loaded?.id != current.id || tokens + ChatTier.of(current).maxTokens <= execution.contextTokens) {
            "This pending turn does not fit the current local model's context. Your draft is kept."
        }
        if (decision != null && loaded?.id == decision.modelID && decision.environmentID != null)
            label = Label(loaded.id, decision.environmentID, decision.observed)
        return loaded
    }

    fun restorePinned(modelID: String, request: AutomaticChatRequest? = null, isCurrent: () -> Boolean): ModelEntry? {
        label = null
        val target = ModelCatalog.entry(modelID) ?: return null
        if (engine.loadedModelId == modelID) {
            check(request == null || engine.pendingChatFits(target, request)) { "This conversation's pending turn does not fit the loaded model's actual context. Your draft is kept." }
            return target.takeIf { isCurrent() }
        }
        check(pendingManual == null && onboarding.activateInstalled(target, request = request, isCurrent = isCurrent)) { "The conversation's local model could not be restored from its verified installed file. Your draft is kept." }
        return target.takeIf { isCurrent() && engine.loadedModelId == modelID }
    }

    fun verifiedPath(model: ModelEntry): String? {
        val path = File(modelsDir, model.filename).absolutePath
        return runCatching { receipts.verify(model, path)?.path }.getOrNull()
    }
}
