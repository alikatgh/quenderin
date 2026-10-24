import Foundation
import Combine

/// A distinct opt-in, independent of the existing task suggestion preference.
@MainActor
public final class AutomaticModelPreferences: ObservableObject {
    public static let shared = AutomaticModelPreferences()
    private let defaults: UserDefaults
    @Published public var enabled: Bool {
        didSet { revision &+= 1; defaults.set(enabled, forKey: "quenderin.automaticModels.enabled") }
    }
    public private(set) var revision: UInt64 = 0
    public private(set) var manualModelID: String?
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "quenderin.automaticModels.enabled")
        manualModelID = defaults.string(forKey: "quenderin.automaticModels.manualModelID")
    }
    public func chooseManually(_ id: String) {
        manualModelID = id
        defaults.set(id, forKey: "quenderin.automaticModels.manualModelID")
        enabled = false // Invalidates every in-flight Automatic decision, including an already disabled mode.
    }
}

/// First-turn only: keeps the selected engine fixed for the rest of a conversation.
/// Reuses OnboardingModel's installed-file activation and recovery; it has no downloader.
@MainActor
public final class AutomaticModelSelection {
    private let onboarding: OnboardingModel
    private let store: InferencePerformanceStore
    private let preferences: AutomaticModelPreferences
    private let deviceBudgetGB: Double
    private let resourceBudget: @MainActor () -> ImageResourceBudget
    private let runtimeAvailable: @MainActor (ModelEntry) -> Bool
    private let nowMs: @MainActor () -> Int64
    private let thermalNominal: @MainActor () -> Bool
    private var failures: [String: Int64] = [:]
    public private(set) var status = "Estimated · no comparable local observations"
    public init(onboarding: OnboardingModel, store: InferencePerformanceStore,
                preferences: AutomaticModelPreferences = .shared, deviceBudgetGB: Double = HardwareProbe.appMemoryBudgetGB(),
                resourceBudget: @escaping @MainActor () -> ImageResourceBudget = { .current() },
                runtimeAvailable: @escaping @MainActor (ModelEntry) -> Bool = { DefaultInferenceEngine.isReal && ModelRuntimeSupport.supports($0) },
                nowMs: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                thermalNominal: @escaping @MainActor () -> Bool = { ThermalMonitor.currentLevel() == .nominal }) {
        self.onboarding = onboarding; self.store = store; self.preferences = preferences; self.deviceBudgetGB = deviceBudgetGB
        self.resourceBudget = resourceBudget; self.runtimeAvailable = runtimeAvailable; self.nowMs = nowMs; self.thermalNominal = thermalNominal
    }
    public func prepare(prompt: String, current: ModelEntry?, history: [ChatMessage]? = nil, options: GenerationOptions? = nil,
                        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) async throws -> ModelEntry? {
        guard preferences.enabled else { return current }
        let revision = preferences.revision
        let now = nowMs()
        failures = failures.filter { now - $0.value < 600_000 }
        let records = await store.samples(nowMs: now)
        let tier = ChatTier.of(model: current)
        let request = (system: tier.systemPrompt, history: history ?? [ChatMessage(role: .user, text: prompt)], options: options ?? tier.chatOptions)
        let loadedID = await onboarding.loadedAutomaticModelID()
        let actual = await onboarding.executionProfile(system: request.system, history: request.history, options: request.options)
        let actualCapacity = await onboarding.loadedAutomaticContextTokens()
        let known = await onboarding.knownExecutionProfiles()
        guard preferences.enabled, preferences.revision == revision, isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let available = resourceBudget()
        let budget = deviceBudgetGB
        let currentLoaded = current != nil && loadedID == current?.id
        // The loaded model's tokenization is authoritative. Alternatives are checked again with
        // their actual tokenizer/context before the exclusive switch transaction can commit.
        let promptTokens = max(1, actual?.promptTokens ?? min(262_144, (prompt.utf8.count + 3) / 4 + 128))
        let requiredContext = promptTokens + request.options.maxTokens
        let freeGB = Double(available.availableMemoryBytes) / 1_073_741_824
        let replacementFreeGB = min(budget, max(0, freeGB) + (currentLoaded ? (current?.ramGB ?? 0) : 0))
        let installed = onboarding.installedAutomaticModels()
        let task = ModelRouter.classify(prompt)
        let requiredTier = ChatTier.of(model: current)
        struct Plan { let model: ModelEntry; let artifact: String; let config: (context: Int, environment: String); let profile: InferenceExecutionProfile?; let isLoaded: Bool }
        let plans: [Plan] = installed.compactMap { model in
            guard failures[model.id] == nil, let artifact = InferencePerformanceIdentity.artifact(model) else { return nil }
            let isLoaded = currentLoaded && model.id == current?.id
            let receipt = (isLoaded ? actual : nil) ?? known.last {
                $0.modelID == model.id && $0.artifactSHA256 == artifact && $0.runtimeID == InferencePerformanceRuntime.id
                    && $0.backendID == InferencePerformanceIdentity.backendID
            }
            // A fresh process can reconstruct only the two load plans the current engine supports.
            // Historical numbers are usable solely after an exact artifact/runtime/backend/device
            // configuration identity match; no arbitrary historical environment is trusted.
            let supported = Self.supportedConfigurations(model: model, budget: budget)
            let historical = supported.first { config in records.contains {
                $0.modelID == model.id && $0.artifactSHA256 == artifact && $0.runtimeID == InferencePerformanceRuntime.id
                    && $0.backendID == InferencePerformanceIdentity.backendID && $0.environmentID == config.environment
                    && $0.contextTokens == config.context
            } }
            let config = receipt.map { (context: $0.contextTokens, environment: $0.environmentID) }
                ?? historical ?? supported[0]
            return Plan(model: model, artifact: artifact, config: config, profile: receipt, isLoaded: isLoaded)
        }
        // Determine the preferred family only after resource, runtime, context and quality gates.
        // A larger but ineligible coder must not exclude a viable current general text model.
        let resourceEligible = plans.filter { plan in
            runtimeAvailable(plan.model) && ModelRuntimeSupport.supports(plan.model)
                && (plan.isLoaded || MemoryFitness.check(model: plan.model, totalGB: budget, freeGB: replacementFreeGB).canLoad)
                && requiredContext <= plan.config.context && available.freeDiskBytes >= 67_108_864
                && ChatTier.of(model: plan.model) == requiredTier && !ModelRuntimeSupport.isMuse(plan.model)
        }
        let preferred = ModelRouter.preferredFamilies(for: task).first { prefix in resourceEligible.contains { $0.model.id.hasPrefix(prefix) } }
        let taskEligible = resourceEligible.filter { plan in
            plan.isLoaded || task == .general || preferred == nil || plan.model.id.hasPrefix(preferred!)
        }
        let routed = ModelRouter.route(prompt: prompt, installed: taskEligible.map(\.model), totalRAMGB: budget,
                                      freeRAMGB: replacementFreeGB)?.modelID
        func candidates() -> [AutomaticModelCandidate] {
            taskEligible.filter { failures[$0.model.id] == nil }.map { plan in
                AutomaticModelCandidate(modelID: plan.model.id, artifactSHA256: plan.artifact,
                    runtimeID: plan.profile?.runtimeID ?? InferencePerformanceRuntime.id,
                    backendID: plan.profile?.backendID ?? InferencePerformanceIdentity.backendID,
                    environmentID: plan.config.environment, contextTokens: plan.config.context,
                    verified: onboarding.isAutomaticModelVerified(plan.model),
                    cacheMode: plan.isLoaded ? (actual?.cacheMode ?? "cold") : "cold")
            }
        }
        var admitted = candidates()
        let currentAdmitted = admitted.contains { $0.modelID == current?.id && $0.admitted }
        let unverified = admitted.filter { c in
            !c.verified && (c.modelID != current?.id || !currentAdmitted)
                && (!currentAdmitted || records.contains { $0.modelID == c.modelID && $0.artifactSHA256 == c.artifactSHA256
                    && $0.runtimeID == c.runtimeID && $0.backendID == c.backendID && $0.environmentID == c.environmentID })
        }.sorted { a, b in
            if (a.modelID == routed) != (b.modelID == routed) { return a.modelID == routed }
            return a.modelID < b.modelID
        }
        if let pending = unverified.first, let model = installed.first(where: { $0.id == pending.modelID }) {
            do { try await onboarding.verifyInstalledForAutomatic(model) }
            catch { failures[model.id] = now }
            guard preferences.enabled, preferences.revision == revision, isCurrent(), !Task.isCancelled else { throw CancellationError() }
            admitted = candidates()
        }
        let decision = AutomaticModelPolicy.choose(currentID: current?.id, candidates: admitted, samples: records,
            promptTokens: promptTokens, expectedOutputTokens: request.options.maxTokens,
            nowMs: now, thermalNominal: thermalNominal(), fallbackID: routed)
        guard let decision, let selected = installed.first(where: { $0.id == decision.modelID }) else {
            // Keeping already allocated working weights needs no second full-model allocation.
            if currentLoaded, let current, runtimeAvailable(current), requiredContext <= (actualCapacity ?? actual?.contextTokens ?? 0) {
                status = "\(current.label) · \(actual?.backendID ?? InferencePerformanceIdentity.backendID) · estimated; keeping the working selected model"
                return current
            }
            status = "No eligible Automatic model; choose a model manually to continue"
            throw InferenceError.loadFailed(reason: "No installed, verified text model currently passes Automatic's memory, context, disk and task gates.")
        }
        status = "\(selected.label) · \(InferencePerformanceIdentity.backendID) · \(decision.observed ? "observed locally" : "estimated; insufficient comparable observations")"
        guard decision.modelID != current?.id else { return current }
        do {
            let targetTier = ChatTier.of(model: selected)
            let targetRequest = (system: targetTier.systemPrompt, history: request.history, options: options ?? targetTier.chatOptions)
            let activated = try await onboarding.activateInstalledForAutomatic(selected, request: targetRequest,
                requiredContextTokens: promptTokens + targetRequest.options.maxTokens, expectedConfiguration: decision.observed ? admitted.first(where: { $0.modelID == selected.id }) : nil) {
                self.preferences.enabled && self.preferences.revision == revision && isCurrent()
            }
            guard activated else { throw CancellationError() }
            // Selection has already been atomically accepted by the loader. A later manual action
            // owns the next selection rather than invalidating a commit after its lease was released.
            if let actual = onboarding.lastAutomaticExecutionProfile,
               let proposed = admitted.first(where: { $0.modelID == selected.id }),
               actual.environmentID != proposed.environmentID || actual.contextTokens != proposed.contextTokens {
                status = "\(selected.label) · \(actual.backendID) · estimated; actual load configuration changed"
            }
            return selected
        } catch { failures[selected.id] = now; throw error }
    }
    static func supportedConfigurations(model: ModelEntry, budget: Double) -> [(context: Int, environment: String)] {
        let preferred = configuration(model: model, budget: budget)
        guard KVCachePolicy.recommend(appBudgetGB: budget, modelWeightsGB: model.ramGB) == .q8_0 else { return [preferred] }
        let fallback = configuration(model: model, budget: budget, cacheType: .f16)
        return preferred == fallback ? [preferred] : [preferred, fallback]
    }
    static func configuration(model: ModelEntry, budget: Double, cacheType: KVCacheType? = nil) -> (context: Int, environment: String) {
        let cache = cacheType ?? KVCachePolicy.recommend(appBudgetGB: budget, modelWeightsGB: model.ramGB)
        var context = ContextWindow.recommend(appBudgetGB: budget, modelWeightsGB: model.ramGB, kvCacheType: cache)
        if ModelRuntimeSupport.isBonsai(model) { context = min(context, ModelRuntimeSupport.bonsaiMaxContextTokens) }
        if ModelRuntimeSupport.isMuse(model) { context = min(context, ModelRuntimeSupport.museMaxContextTokens) }
        if ModelRuntimeSupport.isBeam(model) { context = min(context, 4096) }
        let plan = GpuOffloadPolicy.plan(fileSizeGB: Double(model.downloadBytes ?? Int64(model.ramGB * 1_000_000_000)) / 1_000_000_000,
            deviceBudgetGB: budget, isMoE: MoEShape.detect(model.filename) != nil,
            expertOffloadEnabled: ProcessInfo.processInfo.environment["QUENDERIN_MOE_EXPERT_CPU"] == "1")
        let threads = ThreadPlanner.recommend(performanceCores: HardwareProbe.performanceCoreCount(),
                                             totalCores: ProcessInfo.processInfo.activeProcessorCount)
        return (context, InferencePerformanceIdentity.environment(context: context, cacheType: cache == .q8_0 ? "q8_0" : "f16",
            threads: threads, gpuLayers: plan.nGpuLayers, cpuExperts: plan.experts == .cpu && MoEShape.detect(model.filename) != nil,
            batch: min(PromptBatchDecoder.maximumBatchTokens, context)))
    }
}
