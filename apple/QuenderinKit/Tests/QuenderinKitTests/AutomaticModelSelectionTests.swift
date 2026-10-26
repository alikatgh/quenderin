import XCTest
import Combine
@testable import QuenderinKit

private actor SelectionFixtureEngine: InferenceEngine {
    private var loaded: String?
    private(set) var loads: [String] = []
    private(set) var ordinaryFlags: [Bool] = []
    private(set) var generatedModelIDs: [String?] = []
    private(set) var profileRequests: [[ChatMessage]] = []
    private var profiles: [String: InferenceExecutionProfile] = [:]
    private var nextModelQueryGate: SelectionGate?
    private var knownProfiles: Set<String> = []
    var failID: String?
    var blockedID: String?
    private var unblock: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isBlocked = false
    private var loadDeadline: Task<Void, Never>?
    private var holdReply = false
    private var nextCapStatus: ChatCapStatus = .unknown
    private var capStatus: ChatCapStatus = .unknown
    private var replyEnd: AsyncThrowingStream<String, Error>.Continuation?
    func configure(fail: String? = nil, block: String? = nil) { failID = fail; blockedID = block }
    func blockNextModelQuery(_ gate: SelectionGate) { nextModelQueryGate = gate }
    func loadedModelID() async -> String? {
        if let gate = nextModelQueryGate {
            nextModelQueryGate = nil
            await gate.arriveAndWait()
        }
        return loaded
    }
    func load(model: ModelEntry, at fileURL: URL) async throws {
        loads.append(model.id)
        if model.id == blockedID {
            isBlocked = true
            armLoadDeadline()
            blockedWaiters.forEach { $0.resume() }; blockedWaiters = []
            await withCheckedContinuation { unblock = $0 }
            isBlocked = false
        }
        loaded = nil
        if model.id == failID { throw InferenceError.loadFailed(reason: "fixture load failure") }
        loaded = model.id
        knownProfiles.insert(model.id)
    }
    func setProfile(_ profile: InferenceExecutionProfile, known: Bool = true) {
        profiles[profile.modelID] = profile
        if known { knownProfiles.insert(profile.modelID) } else { knownProfiles.remove(profile.modelID) }
    }
    func loadedContextTokens() async -> Int? { loaded.flatMap { profiles[$0]?.contextTokens } }
    func loadedExecutionProfile(system: String, history: [ChatMessage], options: GenerationOptions) async -> InferenceExecutionProfile? {
        profileRequests.append(history)
        return loaded.flatMap { profiles[$0] }
    }
    func knownExecutionProfiles() async -> [InferenceExecutionProfile] { knownProfiles.compactMap { profiles[$0] } }
    func waitForBlockedLoad() async {
        if isBlocked { return }
        armLoadDeadline()
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    private func armLoadDeadline() {
        guard loadDeadline == nil else { return }
        loadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            _ = await self?.expireLoadWait()
        }
    }
    private func expireLoadWait() {
        guard unblock != nil || !blockedWaiters.isEmpty else { return }
        XCTFail("Timed out waiting for the deterministic model-load fixture")
        blockedWaiters.forEach { $0.resume() }; blockedWaiters = []
        releaseLoad()
    }
    func releaseLoad() {
        loadDeadline?.cancel(); loadDeadline = nil
        blockedID = nil; unblock?.resume(); unblock = nil
    }
    func unload() async { loaded = nil }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        capStatus = nextCapStatus
        nextCapStatus = .unknown
        ordinaryFlags.append(options.collectPerformance)
        generatedModelIDs.append(loaded)
        if holdReply { return openAgentStream() }
        return AsyncThrowingStream { $0.yield("fixture reply"); $0.finish() }
    }
    func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try await generate(prompt: "", options: options)
    }
    func setNextChatCapStatus(_ status: ChatCapStatus) { nextCapStatus = status }
    func chatCapStatus() async -> ChatCapStatus { capStatus }
    func setHoldReply(_ held: Bool) { holdReply = held }
    func finishReply() { replyEnd?.finish(); replyEnd = nil }
    func openAgentStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { replyEnd = $0 }
    }
}

@MainActor
final class AutomaticModelSelectionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["QUENDERIN_TEST_SCRATCH"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: root).appendingPathComponent("automatic-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func preferences() -> AutomaticModelPreferences {
        let suite = "automatic-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AutomaticModelPreferences(defaults: defaults)
    }
    private func model(_ id: String, directory: URL, params: Double = 1, ram: Double = 1) throws -> ModelEntry {
        let file = directory.appendingPathComponent("\(id).gguf")
        try Data("GGUFtiny-\(id)".utf8).write(to: file)
        return ModelEntry(id: id, label: id, filename: file.lastPathComponent, ramGB: ram, sizeLabel: "tiny fixture",
            paramsBillions: params, quantization: "Q4_K_M", urlString: "", sha256: try ModelIntegrity.sha256Hex(of: file))
    }
    func testModeAndManualChoiceSurviveRelaunchIndependentlyOfSuggestions() {
        let suite = "automatic-mode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AutomaticModelPreferences(defaults: defaults)
        XCTAssertFalse(first.enabled)
        first.enabled = true
        XCTAssertTrue(AutomaticModelPreferences(defaults: defaults).enabled)
        let token = first.revision
        first.chooseManually("manual-model")
        XCTAssertGreaterThan(first.revision, token)
        let relaunched = AutomaticModelPreferences(defaults: defaults)
        XCTAssertFalse(relaunched.enabled)
        XCTAssertEqual(relaunched.manualModelID, "manual-model")
    }
    func testManualRememberedModelWinsAfterRelaunchWithAutomaticOff() async throws {
        let dir = try directory()
        let manual = ModelCatalog.smallest
        let other = ModelCatalog.models.first { $0.id != manual.id && ModelRuntimeSupport.supports($0) }!
        // Fake downloader+engine, no actual model execution or network.
        let prefs = preferences(); prefs.chooseManually(manual.id)
        try Data("GGUFfixture".utf8).write(to: dir.appendingPathComponent(manual.filename))
        let engine = SelectionFixtureEngine()
        let onboarding = OnboardingModel(downloader: MockModelDownloader(), engine: engine, modelsDir: dir,
            availableDiskBytes: { _ in .max }, recallActiveModelID: { other.id }, rememberActiveModelID: { _ in }, automaticPreferences: prefs)
        await onboarding.start()
        let loaded = await engine.loadedModelID()
        XCTAssertEqual(loaded, manual.id)
    }
    func testAutomaticLoadFailureRestoresPreviousOnceAndKeepsReady() async throws {
        let dir = try directory(), previous = try model("previous", directory: dir), target = try model("target", directory: dir)
        let raw = SelectionFixtureEngine(), engine = CoordinatedInferenceEngine(raw)
        let onboarding = OnboardingModel(downloader: MockModelDownloader(), engine: engine, modelsDir: dir,
            availableDiskBytes: { _ in .max }, recallActiveModelID: { nil }, rememberActiveModelID: { _ in }, automaticPreferences: preferences())
        await onboarding.install(previous)
        await raw.configure(fail: target.id)
        do { _ = try await onboarding.activateInstalledForAutomatic(target, isCurrent: { true }); XCTFail("must fail") }
        catch { }
        let loads = await raw.loads, loaded = await engine.loadedModelID()
        XCTAssertEqual(loads, [previous.id, target.id, previous.id])
        XCTAssertEqual(loaded, previous.id)
        guard case .ready(let ready) = onboarding.phase else { return XCTFail("must retain usable chat") }
        XCTAssertEqual(ready.id, previous.id)
    }
    func testManualChoiceInvalidatesInFlightAutomaticLoadAndWins() async throws {
        let dir = try directory(), previous = try model("previous", directory: dir), target = try model("target", directory: dir)
        let prefs = preferences(); prefs.enabled = true
        let raw = SelectionFixtureEngine(), engine = CoordinatedInferenceEngine(raw)
        let onboarding = OnboardingModel(downloader: MockModelDownloader(), engine: engine, modelsDir: dir,
            availableDiskBytes: { _ in .max }, recallActiveModelID: { nil }, rememberActiveModelID: { _ in }, automaticPreferences: prefs)
        await onboarding.install(previous)
        await raw.configure(block: target.id)
        let revision = prefs.revision
        let automatic = Task {
            try await onboarding.activateInstalledForAutomatic(target) { prefs.enabled && prefs.revision == revision }
        }
        await raw.waitForBlockedLoad()
        onboarding.beginInstall(previous)
        await raw.releaseLoad()
        do { _ = try await automatic.value; XCTFail("stale Automatic must fail") } catch { }
        let loaded = await engine.loadedModelID()
        XCTAssertEqual(loaded, previous.id)
        XCTAssertFalse(prefs.enabled)
        XCTAssertEqual(prefs.manualModelID, previous.id)
        guard case .ready(let ready) = onboarding.phase else { return XCTFail("manual choice must be ready") }
        XCTAssertEqual(ready.id, previous.id)
    }
    func testTamperedInstalledFileCannotReachAutomaticEngineLoad() async throws {
        let dir = try directory(), previous = try model("previous", directory: dir), target = try model("target", directory: dir)
        let raw = SelectionFixtureEngine(), engine = CoordinatedInferenceEngine(raw)
        let onboarding = OnboardingModel(downloader: MockModelDownloader(behavior: .failTransport(reason: "must never download")), engine: engine,
            modelsDir: dir, availableDiskBytes: { _ in .max }, recallActiveModelID: { nil }, rememberActiveModelID: { _ in }, automaticPreferences: preferences())
        await onboarding.install(previous)
        let file = dir.appendingPathComponent(target.filename)
        try Data("GGUFtampered".utf8).write(to: file)
        do { _ = try await onboarding.activateInstalledForAutomatic(target, isCurrent: { true }); XCTFail("must reject tampering") } catch { }
        let loads = await raw.loads
        XCTAssertEqual(loads, [previous.id])
        XCTAssertEqual(try Data(contentsOf: file), Data("GGUFtampered".utf8), "invalid file is preserved")
    }
    func testAgentOwnershipBlocksAutomaticDuringToolAndApprovalGaps() async throws {
        let dir = try directory(), previous = try model("previous", directory: dir), target = try model("target", directory: dir)
        let engine = CoordinatedInferenceEngine(SelectionFixtureEngine())
        try await engine.load(model: previous, at: dir.appendingPathComponent(previous.filename))
        let ownership = try await engine.retainModelForAgentRun()
        let duringTool = try await engine.loadForAutomaticIfIdle(model: target, at: dir.appendingPathComponent(target.filename))
        XCTAssertFalse(duringTool)
        try await ownership.resume()
        let afterRun = try await engine.loadForAutomaticIfIdle(model: target, at: dir.appendingPathComponent(target.filename))
        XCTAssertTrue(afterRun)
    }
    func testActiveAgentStreamBlocksAutomaticLoadWithoutCancellingIt() async throws {
        let dir = try directory(), previous = try model("previous", directory: dir), target = try model("target", directory: dir)
        let raw = SelectionFixtureEngine(), engine = CoordinatedInferenceEngine(raw)
        try await engine.load(model: previous, at: dir.appendingPathComponent(previous.filename))
        await raw.setHoldReply(true)
        let agentStream = try await engine.generate(prompt: "agent", options: .init())
        let switched = try await engine.loadForAutomaticIfIdle(model: target, at: dir.appendingPathComponent(target.filename))
        XCTAssertFalse(switched)
        let loads = await raw.loads
        XCTAssertEqual(loads, [previous.id])
        await raw.finishReply()
        for try await _ in agentStream { }
    }
    func testFailedPreparationKeepsDraftDocumentsAndHistoryUntilAcceptance() async throws {
        let raw = SelectionFixtureEngine()
        var accepted = false
        let chat = ChatModel(engine: raw, prepareFirstTurn: { _, _, _ in throw InferenceError.loadFailed(reason: "fixture") })
        let docs = [AttachedDocument(name: "research.txt", text: "attached text")]
        await chat.send("retained draft", documents: docs, onAccepted: { accepted = true })
        XCTAssertFalse(accepted)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNotNil(chat.preparationError)
        XCTAssertFalse(chat.isGenerating)
        let flags = await raw.ordinaryFlags
        XCTAssertTrue(flags.isEmpty)
    }
    func testFirstTurnHookRunsOnceAndOrdinaryChatExplicitlyOptsIn() async {
        let raw = SelectionFixtureEngine()
        var preparations = 0
        let chat = ChatModel(engine: raw, prepareFirstTurn: { _, model, _ in preparations += 1; return (model, "observed locally") })
        await chat.send("first")
        await chat.send("second")
        XCTAssertEqual(preparations, 1)
        let flags = await raw.ordinaryFlags
        XCTAssertEqual(flags, [true, true])
        XCTAssertFalse(GenerationOptions().collectPerformance, "raw/agent requests default to no collection")
        chat.reset()
        await chat.send("new chat")
        XCTAssertEqual(preparations, 2)
    }
}

private actor SelectionGate {
    private var reached = false
    private var opened = false
    private var deadlineArmed = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func arriveAndWait() async {
        guard !opened else { return }
        armDeadline()
        reached = true
        observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilReached() async {
        if reached || opened { return }
        armDeadline()
        await withCheckedContinuation { observers.append($0) }
    }
    private func armDeadline() {
        guard !deadlineArmed else { return }
        deadlineArmed = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.expireWait()
        }
    }
    private func expireWait() {
        guard !opened else { return }
        XCTFail("Timed out waiting for the deterministic Automatic-selection fixture")
        open()
    }
    func open() {
        opened = true
        observers.forEach { $0.resume() }; observers = []
        release?.resume(); release = nil
    }
}

/// Deterministically suspends after native loading and immediately before the final acceptance callback.
private actor AcceptanceGateEngine: InferenceEngine {
    let underlying: CoordinatedInferenceEngine
    let gate: SelectionGate
    init(_ underlying: CoordinatedInferenceEngine, gate: SelectionGate) { self.underlying = underlying; self.gate = gate }
    func loadedModelID() async -> String? { await underlying.loadedModelID() }
    func loadedContextTokens() async -> Int? { await underlying.loadedContextTokens() }
    func loadedExecutionProfile(system: String, history: [ChatMessage], options: GenerationOptions) async -> InferenceExecutionProfile? {
        await underlying.loadedExecutionProfile(system: system, history: history, options: options)
    }
    func knownExecutionProfiles() async -> [InferenceExecutionProfile] { await underlying.knownExecutionProfiles() }
    func load(model: ModelEntry, at fileURL: URL) async throws { try await underlying.load(model: model, at: fileURL) }
    func unload() async { await underlying.unload() }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try await underlying.generate(prompt: prompt, options: options)
    }
    func retainModelForAgentRun() async throws -> SpecialistInferenceLease { try await underlying.retainModelForAgentRun() }
    func loadForAutomaticIfIdle(model: ModelEntry, at fileURL: URL,
        stillCurrent: @escaping @Sendable () async -> Bool, accept: @escaping @Sendable () async -> Bool) async throws -> Bool {
        try await underlying.loadForAutomaticIfIdle(model: model, at: fileURL, stillCurrent: stillCurrent, accept: {
            await self.gate.arriveAndWait()
            return await accept()
        })
    }
}

extension AutomaticModelSelectionTests {
    private struct ControllerHarness {
        let raw: SelectionFixtureEngine
        let engine: any InferenceEngine
        let onboarding: OnboardingModel
        let preferences: AutomaticModelPreferences
        let store: InferencePerformanceStore
        let selection: AutomaticModelSelection
    }
    private var fixtureNow: Int64 { 1_792_800_000_000 }
    private func profile(_ model: ModelEntry, context: Int = 2048, cache: String = "prefix", prompt: Int = 128,
                         environment: String? = nil) -> InferenceExecutionProfile {
        .init(modelID: model.id, artifactSHA256: model.sha256!, runtimeID: InferencePerformanceRuntime.id,
            backendID: InferencePerformanceIdentity.backendID,
            environmentID: environment ?? InferencePerformanceIdentity.digest("fixture-\(model.id)-\(context)"),
            contextTokens: context, cacheMode: cache, promptTokens: prompt)
    }
    private func addSamples(_ profile: InferenceExecutionProfile, decodeMs: Double,
                            store: InferencePerformanceStore, count: Int = 3) async {
        for index in 0..<count {
            let sample = InferencePerformanceSample(modelID: profile.modelID, artifactSHA256: profile.artifactSHA256,
                runtimeID: profile.runtimeID, backendID: profile.backendID, environmentID: profile.environmentID,
                contextTokens: profile.contextTokens, promptTokens: profile.promptTokens ?? 128,
                prefillTokens: profile.cacheMode == "prefix" ? 64 : 128, decodedTokens: 64,
                prefillMs: 128, decodeMs: decodeMs, firstTokenMs: 130, maxGapMs: 20, loadMs: 0,
                cacheMode: profile.cacheMode, thermalState: "nominal", recordedAtMs: fixtureNow - Int64(index))
            let recorded = await store.record(sample, nowMs: fixtureNow)
            XCTAssertTrue(recorded)
        }
    }
    private func harness(models: [ModelEntry], current: ModelEntry, directory: URL,
                         raw: SelectionFixtureEngine? = nil, engine: (any InferenceEngine)? = nil,
                         freeMemoryGB: Double = 8, budgetGB: Double = 16,
                         verify: (@Sendable (ModelEntry, URL) async throws -> Void)? = nil) async throws -> ControllerHarness {
        let raw = raw ?? SelectionFixtureEngine()
        let engine = engine ?? CoordinatedInferenceEngine(raw)
        let prefs = preferences()
        let onboarding = OnboardingModel(downloader: MockModelDownloader(behavior: .failTransport(reason: "Automatic must not download")),
            engine: engine, modelsDir: directory, availableDiskBytes: { _ in .max }, recallActiveModelID: { nil },
            rememberActiveModelID: { _ in }, automaticPreferences: prefs, automaticCatalog: models, verifyAutomaticArtifact: verify)
        await onboarding.install(current)
        guard case .ready = onboarding.phase else { throw InferenceError.loadFailed(reason: "fixture setup failed") }
        prefs.enabled = true
        let store = InferencePerformanceStore(file: directory.appendingPathComponent("performance.json"))
        let now = fixtureNow
        let selection = AutomaticModelSelection(onboarding: onboarding, store: store, preferences: prefs, deviceBudgetGB: budgetGB,
            resourceBudget: { ImageResourceBudget(availableMemoryBytes: Int64(freeMemoryGB * 1_073_741_824), freeDiskBytes: .max) },
            runtimeAvailable: { _ in true }, nowMs: { now }, thermalNominal: { true })
        return ControllerHarness(raw: raw, engine: engine, onboarding: onboarding, preferences: prefs, store: store, selection: selection)
    }

    func testPrepareKeepsAllocatedModelWhenLiveFreeMemoryCannotAllocateItAgain() async throws {
        let dir = try directory(), current = try model("llama-current", directory: dir, params: 4, ram: 4)
        let raw = SelectionFixtureEngine(), actual = profile(current)
        await raw.setProfile(actual)
        let h = try await harness(models: [current], current: current, directory: dir, raw: raw, freeMemoryGB: 0.05)
        await addSamples(actual, decodeMs: 640, store: h.store)
        let selected = try await h.selection.prepare(prompt: "A short question", current: current)
        XCTAssertEqual(selected?.id, current.id)
        XCTAssertTrue(h.selection.status.contains("observed locally"))
        let loads = await raw.loads
        XCTAssertEqual(loads, [current.id], "Retaining working allocations does not trigger another load")
    }

    func testPrepareComputesTaskFamilyAfterTierAndResourceAdmission() async throws {
        let dir = try directory(), current = try model("gemma3-4b", directory: dir, params: 4, ram: 4)
        let coder = try model("qwen25-coder-7b", directory: dir, params: 7, ram: 7)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(current))
        await raw.setProfile(profile(coder, cache: "cold"))
        let h = try await harness(models: [current, coder], current: current, directory: dir, raw: raw)
        let selected = try await h.selection.prepare(prompt: "Write Swift code for a binary search function", current: current)
        XCTAssertEqual(selected?.id, current.id, "An ineligible larger coder cannot veto the current small-tier model")
    }

    func testPrepareUsesActualPrefixSamplesForCurrentAndColdSamplesForAlternative() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a), bProfile = profile(b, cache: "cold")
        await raw.setProfile(aProfile); await raw.setProfile(bProfile)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(bProfile, decodeMs: 100, store: h.store)
        let selected = try await h.selection.prepare(prompt: "A short question", current: a)
        XCTAssertEqual(selected?.id, b.id)
        XCTAssertTrue(h.selection.status.contains("observed locally"), "Must use prefix evidence rather than an estimated fallback")
        let loaded = await h.engine.loadedModelID()
        XCTAssertEqual(loaded, b.id)
    }

    func testPrepareCanUseEffectiveF16FallbackProfilesForCurrentAndAlternative() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a, context: 512), bProfile = profile(b, context: 512, cache: "cold")
        await raw.setProfile(aProfile); await raw.setProfile(bProfile)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(bProfile, decodeMs: 100, store: h.store)
        XCTAssertNotEqual(AutomaticModelSelection.configuration(model: a, budget: 16).context, 512)
        let selected = try await h.selection.prepare(prompt: "A short question", current: a)
        XCTAssertEqual(selected?.id, b.id)
        XCTAssertTrue(h.selection.status.contains("observed locally"))
        XCTAssertEqual(h.onboarding.lastAutomaticExecutionProfile?.contextTokens, 512)
    }

    func testPrepareRejectsActualFallbackContextShrinkBeforeCommittingOrGenerating() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a)
        await raw.setProfile(aProfile)
        await raw.setProfile(profile(b, context: 256, cache: "cold"), known: false)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        let predicted = AutomaticModelSelection.configuration(model: b, budget: 16)
        let proposed = profile(b, context: predicted.context, cache: "cold", environment: predicted.environment)
        await addSamples(proposed, decodeMs: 100, store: h.store)
        do { _ = try await h.selection.prepare(prompt: "A short question", current: a); XCTFail("Actual 256-token context cannot fit 128+256 tokens") }
        catch { }
        let loaded = await h.engine.loadedModelID(), generated = await raw.generatedModelIDs
        XCTAssertEqual(loaded, a.id)
        XCTAssertTrue(generated.isEmpty)
        guard case .ready(let selected) = h.onboarding.phase else { return XCTFail("Previous chat must remain visible") }
        XCTAssertEqual(selected.id, a.id)
    }

    func testPrepareInvalidatedImmediatelyBeforeFinalAcceptanceRollsBackUnderLease() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a), bProfile = profile(b, cache: "cold")
        await raw.setProfile(aProfile); await raw.setProfile(bProfile)
        let coordinated = CoordinatedInferenceEngine(raw), gate = SelectionGate()
        let engine = AcceptanceGateEngine(coordinated, gate: gate)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw, engine: engine)
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(bProfile, decodeMs: 100, store: h.store)
        let selecting = Task { try await h.selection.prepare(prompt: "A short question", current: a) }
        await gate.waitUntilReached() // Native load already succeeded; the original validity callback returned true.
        h.preferences.enabled = false
        do { _ = try await coordinated.retainModelForAgentRun(); XCTFail("Unaccepted transient model must remain exclusive") } catch { }
        await gate.open()
        do { _ = try await selecting.value; XCTFail("Invalidated selection must roll back") } catch { }
        let loaded = await h.engine.loadedModelID()
        XCTAssertEqual(loaded, a.id)
        guard case .ready(let selected) = h.onboarding.phase else { return XCTFail("Previous phase must remain ready") }
        XCTAssertEqual(selected.id, a.id)
        let ownership = try await coordinated.retainModelForAgentRun()
        try await ownership.resume()
    }

    func testNewChatInvalidatesRealPrepareDuringLazyArtifactVerification() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a), bProfile = profile(b, cache: "cold"), gate = SelectionGate()
        await raw.setProfile(aProfile); await raw.setProfile(bProfile)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw, verify: { model, file in
            await gate.arriveAndWait()
            try await ModelArtifactSet.inBackground { try InferencePerformanceIdentity.verifyInstalled(model, firstFile: file) }
        })
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(bProfile, decodeMs: 100, store: h.store)
        let chat = ChatModel(engine: h.engine, prepareFirstTurn: { prompt, current, preparation in
            let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
            return (selected, h.selection.status)
        })
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence())
        var accepted = false
        let sending = Task { await chat.send("Pending draft", model: a, onAccepted: { accepted = true }) }
        await gate.waitUntilReached()
        coordinator.startNew() // Transcript is still empty; this must still invalidate the preparation.
        await gate.open()
        await sending.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(chat.messages.isEmpty)
        let loads = await raw.loads
        XCTAssertEqual(loads, [a.id])
        XCTAssertFalse(chat.isGenerating)
    }

    func testHistoryRestoresStickyModelAndExplicitManualPinSurvivesRelaunch() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(a)); await raw.setProfile(profile(b))
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        let persistence = InMemoryConversationPersistence()
        let chat = ChatModel(engine: h.engine, prepareFirstTurn: { prompt, current, preparation in
            let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
            return (selected, h.selection.status)
        })
        let coordinator = ConversationCoordinator(chat: chat, persistence: persistence, restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        await chat.send("Conversation A", model: a); coordinator.persist()
        let aID = coordinator.currentID!
        coordinator.startNew()
        try await h.engine.load(model: b, at: dir.appendingPathComponent(b.filename))
        await chat.send("Conversation B", model: b); coordinator.persist()
        coordinator.open(aID)
        await chat.send("Follow up A", model: b); coordinator.persist()
        let loaded = await h.engine.loadedModelID(), generated = await raw.generatedModelIDs
        XCTAssertEqual(loaded, a.id)
        XCTAssertEqual(generated.last!, a.id)
        XCTAssertEqual(coordinator.pinnedModelID, a.id)
        coordinator.chooseModelManually(b.id)
        XCTAssertEqual(persistence.loadIndex().first(where: { $0.id == aID })?.automaticModelID, b.id)
        let relaunched = ConversationCoordinator(chat: ChatModel(engine: h.engine), persistence: persistence)
        relaunched.open(aID)
        XCTAssertEqual(relaunched.pinnedModelID, b.id)
    }

    func testMissingHistoryPinPreservesDraftAttachmentsAndTranscriptWithoutDownload() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(a)); await raw.setProfile(profile(b))
        let h = try await harness(models: [a, b], current: b, directory: dir, raw: raw)
        let persistence = InMemoryConversationPersistence()
        persistence.saveTranscript(id: "history-a", messages: [.init(role: .user, text: "Original A"), .init(role: .assistant, text: "Saved answer")])
        persistence.saveIndex([.init(id: "history-a", title: "Original A", updatedAt: fixtureNow, modelID: a.id, automaticModelID: a.id, hasOrdinaryInference: true)])
        let chat = ChatModel(engine: h.engine)
        let coordinator = ConversationCoordinator(chat: chat, persistence: persistence, restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        let before = chat.messages
        try FileManager.default.removeItem(at: dir.appendingPathComponent(a.filename))
        var accepted = false
        await chat.send("Retained draft", documents: [.init(name: "research.txt", text: "Retained document")], model: b,
            onAccepted: { accepted = true })
        XCTAssertFalse(accepted)
        XCTAssertEqual(chat.messages, before)
        XCTAssertTrue(chat.preparationError?.contains("not installed") == true)
        let loads = await raw.loads
        XCTAssertEqual(loads, [b.id])
        XCTAssertEqual(coordinator.pinnedModelID, a.id)
    }
}

extension AutomaticModelSelectionTests {
    func testPendingManualHandoffPreservesLongLivedComposerAcrossLoadingPhase() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let manual = try model("llama-manual", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a), bProfile = profile(b, cache: "cold")
        await raw.setProfile(aProfile); await raw.setProfile(bProfile); await raw.setProfile(profile(manual))
        let h = try await harness(models: [a, b, manual], current: a, directory: dir, raw: raw)
        await addSamples(aProfile, decodeMs: 640, store: h.store); await addSamples(bProfile, decodeMs: 100, store: h.store)
        let chat = ChatModel(engine: h.engine, prepareFirstTurn: { prompt, current, preparation in
            let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
            return (selected, h.selection.status)
        })
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence())
        h.onboarding.onManualSelectionCommitted = { coordinator.chooseModelManually($0.id) }
        chat.composer.draft = "Preserved during manual handoff"
        chat.composer.pendingDocuments = [.init(name: "evidence.txt", text: "Attached evidence")]
        let composerBeforeUnmount = chat.composer
        var accepted = false
        var phases: [OnboardingPhase] = []
        let subscription = h.onboarding.$phase.sink { phases.append($0) }
        await raw.configure(block: b.id)
        let sending = Task { await chat.send(chat.composer.draft, documents: chat.composer.pendingDocuments, model: a,
            onAccepted: { accepted = true; chat.composer.draft = ""; chat.composer.pendingDocuments = [] }) }
        await raw.waitForBlockedLoad()
        h.onboarding.beginInstall(manual)
        await raw.releaseLoad()
        await sending.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(phases.contains(.loading(manual)), "Exercise the handoff that removes ChatView")
        let composerAfterRemount = coordinator.chat.composer
        XCTAssertTrue(composerBeforeUnmount === composerAfterRemount)
        XCTAssertEqual(composerAfterRemount.draft, "Preserved during manual handoff")
        XCTAssertEqual(composerAfterRemount.pendingDocuments, [.init(name: "evidence.txt", text: "Attached evidence")])
        XCTAssertTrue(chat.messages.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testLegacyAvatarModelIDNeverBecomesAnAutomaticPinWhenModeIsOff() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(a)); await raw.setProfile(profile(b))
        let h = try await harness(models: [a, b], current: b, directory: dir, raw: raw)
        h.preferences.enabled = false
        let persistence = FileConversationPersistence(directory: dir.appendingPathComponent("conversations"))
        persistence.saveTranscript(id: "legacy", messages: [.init(role: .user, text: "Legacy question"), .init(role: .assistant, text: "Legacy answer")])
        persistence.saveIndex([.init(id: "legacy", title: "Legacy", updatedAt: fixtureNow, modelID: a.id)])
        let chat = ChatModel(engine: h.engine)
        let coordinator = ConversationCoordinator(chat: chat, persistence: persistence, restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        XCTAssertNil(coordinator.pinnedModelID)
        XCTAssertNil(chat.hasOrdinaryInference)
        await chat.send("Follow up using global manual model", model: b)
        coordinator.persist()
        let generated = await raw.generatedModelIDs, loads = await raw.loads
        XCTAssertEqual(generated.last!, b.id)
        XCTAssertEqual(loads, [b.id])
        XCTAssertNil(persistence.loadIndex().first?.automaticModelID)
        coordinator.chooseModelManually(a.id)
        XCTAssertNil(coordinator.pinnedModelID, "A manual choice must not create an Automatic pin on a legacy chat")
    }

    func testGuidedOnlyHistoryPersistsFalseAndRunsAutomaticForFirstOrdinaryInference() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a), bProfile = profile(b, cache: "cold")
        await raw.setProfile(aProfile); await raw.setProfile(bProfile)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        await addSamples(aProfile, decodeMs: 640, store: h.store); await addSamples(bProfile, decodeMs: 100, store: h.store)
        let persistence = FileConversationPersistence(directory: dir.appendingPathComponent("conversations"))
        let guided = ChatModel(engine: h.engine)
        let original = ConversationCoordinator(chat: guided, persistence: persistence)
        guided.recordGuidedTurn(userText: "Open an application", assistantText: "Use the local agent")
        XCTAssertEqual(persistence.loadIndex().first?.hasOrdinaryInference, false)
        XCTAssertNil(persistence.loadIndex().first?.automaticModelID)
        let id = original.currentID!
        let restored = ChatModel(engine: h.engine, prepareFirstTurn: { prompt, current, preparation in
            let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
            return (selected, h.selection.status)
        })
        let coordinator = ConversationCoordinator(chat: restored, persistence: persistence, restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        XCTAssertEqual(restored.hasOrdinaryInference, false)
        await restored.send("A normal question", model: a)
        coordinator.persist()
        let loaded = await h.engine.loadedModelID(), requests = await raw.profileRequests
        XCTAssertEqual(loaded, b.id)
        XCTAssertTrue(requests.contains(where: { $0.count == 3 }), "Selection receives guided history plus pending ordinary question")
        XCTAssertEqual(persistence.loadIndex().first(where: { $0.id == id })?.hasOrdinaryInference, true)
        XCTAssertEqual(persistence.loadIndex().first(where: { $0.id == id })?.automaticModelID, b.id)
    }

    func testLegacyUnknownHistoryDoesNotRerouteItsFirstFollowUp() async throws {
        let dir = try directory(), current = try model("llama-current", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(current))
        let h = try await harness(models: [current], current: current, directory: dir, raw: raw)
        var preparations = 0
        let chat = ChatModel(engine: h.engine, prepareFirstTurn: { _, model, _ in preparations += 1; return (model, "Automatic") })
        let persistence = InMemoryConversationPersistence()
        persistence.saveTranscript(id: "legacy", messages: [.init(role: .user, text: "Earlier question")])
        persistence.saveIndex([.init(id: "legacy", title: "Earlier", updatedAt: fixtureNow, modelID: current.id)])
        let coordinator = ConversationCoordinator(chat: chat, persistence: persistence)
        await chat.send("Follow up", model: current)
        coordinator.persist()
        XCTAssertEqual(preparations, 0)
        XCTAssertNil(coordinator.pinnedModelID)
    }

    func testFreshControllerAdmitsOnlyExactSupportedPersistedF16FallbackIdentity() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir, ram: 2.5)
        let raw = SelectionFixtureEngine(), aProfile = profile(a, context: 4096)
        let fallback = AutomaticModelSelection.configuration(model: b, budget: 4, cacheType: .f16)
        let bProfile = profile(b, context: fallback.context, cache: "cold", environment: fallback.environment)
        await raw.setProfile(aProfile); await raw.setProfile(bProfile, known: false)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw, freeMemoryGB: 4, budgetGB: 4)
        await addSamples(aProfile, decodeMs: 640, store: h.store); await addSamples(bProfile, decodeMs: 100, store: h.store)
        let processReceipts = await raw.knownExecutionProfiles()
        XCTAssertFalse(processReceipts.contains(where: { $0.modelID == b.id }))
        XCTAssertNotEqual(fallback.environment, AutomaticModelSelection.configuration(model: b, budget: 4).environment)
        let selected = try await h.selection.prepare(prompt: "A short question", current: a)
        XCTAssertEqual(selected?.id, b.id)
        XCTAssertTrue(h.selection.status.contains("observed locally"), "Persisted exact fallback evidence must remain usable after receipt loss")
    }

    func testPersistedFallbackEvidenceCannotCommitADifferentActualLoadConfiguration() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir, ram: 2.5)
        let raw = SelectionFixtureEngine(), aProfile = profile(a, context: 4096)
        let fallback = AutomaticModelSelection.configuration(model: b, budget: 4, cacheType: .f16)
        let preferred = AutomaticModelSelection.configuration(model: b, budget: 4)
        await raw.setProfile(aProfile)
        await raw.setProfile(profile(b, context: preferred.context, cache: "cold", environment: preferred.environment), known: false)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw, freeMemoryGB: 4, budgetGB: 4)
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(profile(b, context: fallback.context, cache: "cold", environment: fallback.environment), decodeMs: 100, store: h.store)
        do { _ = try await h.selection.prepare(prompt: "A short question", current: a); XCTFail("Observed f16 identity must not authorize a different q8 load") }
        catch { }
        let loaded = await h.engine.loadedModelID(), loads = await raw.loads
        XCTAssertEqual(loaded, a.id)
        XCTAssertEqual(loads, [a.id, b.id, a.id])
    }

    func testActualTargetTokenizerGrowthRejectsFullPendingRequestBeforeCommit() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a, context: 2048, prompt: 128)
        // The target's template/tokenizer expands the same pending request to 2,000 tokens.
        let bActual = profile(b, context: 2048, cache: "cold", prompt: 2000)
        await raw.setProfile(aProfile); await raw.setProfile(bActual)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(bActual.nextRequest(cacheMode: "cold", promptTokens: 128), decodeMs: 100, store: h.store)
        let fullHistory = [ChatMessage(role: .user, text: "Earlier guided question"), ChatMessage(role: .assistant, text: "Guidance"),
                           ChatMessage(role: .user, text: "Full pending question with attached text")]
        do { _ = try await h.selection.prepare(prompt: "Pending question", current: a, history: fullHistory); XCTFail("2,000 + 256 exceeds target's actual 2,048 capacity") }
        catch { }
        let loaded = await h.engine.loadedModelID(), requests = await raw.profileRequests, generated = await raw.generatedModelIDs
        XCTAssertEqual(loaded, a.id)
        XCTAssertTrue(requests.contains(where: { $0 == fullHistory }))
        XCTAssertTrue(generated.isEmpty)
    }
}

extension AutomaticModelSelectionTests {
    func testComposerDraftAndAttachmentsFollowConversationIdentityAcrossAtoBtoA() {
        let chat = ChatModel(engine: SelectionFixtureEngine())
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence())
        let sharedComposer = chat.composer
        chat.recordGuidedTurn(userText: "Conversation A", assistantText: "A guidance")
        let aID = coordinator.currentID!
        chat.composer.draft = "Draft belonging to A"
        chat.composer.pendingDocuments = [.init(name: "a.txt", text: "A attachment")]
        chat.composer.attachmentNotice = "A notice"
        coordinator.startNew()
        XCTAssertTrue(chat.composer.draft.isEmpty)
        XCTAssertTrue(chat.composer.pendingDocuments.isEmpty)
        XCTAssertNil(chat.composer.attachmentNotice)
        chat.recordGuidedTurn(userText: "Conversation B", assistantText: "B guidance")
        let bID = coordinator.currentID!
        chat.composer.draft = "Draft belonging to B"
        chat.composer.pendingDocuments = [.init(name: "b.txt", text: "B attachment")]
        coordinator.open(aID)
        XCTAssertTrue(chat.composer === sharedComposer, "Model-loading view lifetime still uses one live composer owner")
        XCTAssertEqual(chat.composer.draft, "Draft belonging to A")
        XCTAssertEqual(chat.composer.pendingDocuments, [.init(name: "a.txt", text: "A attachment")])
        XCTAssertEqual(chat.composer.attachmentNotice, "A notice")
        coordinator.open(bID)
        XCTAssertEqual(chat.composer.draft, "Draft belonging to B")
        XCTAssertEqual(chat.composer.pendingDocuments, [.init(name: "b.txt", text: "B attachment")])
        XCTAssertNil(chat.composer.attachmentNotice)
    }

    func testHistoryPinRestorationValidatesTargetsFullPendingPromptAndRollsBackOverflow() async throws {
        let dir = try directory(), pinned = try model("llama-pinned", directory: dir), current = try model("llama-current", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(current, context: 2048, prompt: 128))
        await raw.setProfile(profile(pinned, context: 2048, cache: "cold", prompt: 1600))
        let h = try await harness(models: [pinned, current], current: current, directory: dir, raw: raw)
        h.preferences.enabled = false // A genuine Automatic pin must restore safely even after the mode is turned off.
        let persistence = InMemoryConversationPersistence()
        let saved: [ChatMessage] = [.init(role: .user, text: "Earlier pinned question"), .init(role: .assistant, text: "Pinned answer")]
        persistence.saveTranscript(id: "pinned", messages: saved)
        persistence.saveIndex([.init(id: "pinned", title: "Pinned", updatedAt: fixtureNow, modelID: pinned.id,
                                    automaticModelID: pinned.id, hasOrdinaryInference: true)])
        let chat = ChatModel(engine: h.engine)
        let coordinator = ConversationCoordinator(chat: chat, persistence: persistence, restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        chat.composer.draft = "Pending follow-up"
        chat.composer.pendingDocuments = [.init(name: "follow-up.txt", text: "Full pending attachment")]
        var accepted = false
        await chat.send(chat.composer.draft, documents: chat.composer.pendingDocuments, options: .init(maxTokens: 512), model: current,
                        onAccepted: { accepted = true; chat.composer.draft = ""; chat.composer.pendingDocuments = [] })
        let loaded = await h.engine.loadedModelID(), loads = await raw.loads, requests = await raw.profileRequests
        XCTAssertEqual(loaded, current.id)
        XCTAssertEqual(loads, [current.id, pinned.id, current.id])
        XCTAssertFalse(accepted)
        XCTAssertEqual(chat.messages, saved)
        XCTAssertEqual(chat.composer.draft, "Pending follow-up")
        XCTAssertEqual(chat.composer.pendingDocuments, [.init(name: "follow-up.txt", text: "Full pending attachment")])
        XCTAssertTrue(requests.contains(where: { $0.count == 3 && $0.last?.text.contains("Full pending attachment") == true }))
        XCTAssertTrue(chat.preparationError?.contains("actual context is too small") == true)
        XCTAssertEqual(coordinator.pinnedModelID, pinned.id)
    }
}

extension AutomaticModelSelectionTests {
    func testNewOnEmptyPendingConversationPreservesAccessibleDraftAndRejectsOldPreparation() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine(), aProfile = profile(a), bProfile = profile(b, cache: "cold"), gate = SelectionGate()
        await raw.setProfile(aProfile); await raw.setProfile(bProfile)
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw, verify: { model, file in
            await gate.arriveAndWait()
            try await ModelArtifactSet.inBackground { try InferencePerformanceIdentity.verifyInstalled(model, firstFile: file) }
        })
        await addSamples(aProfile, decodeMs: 640, store: h.store)
        await addSamples(bProfile, decodeMs: 100, store: h.store)
        let chat = ChatModel(engine: h.engine, prepareFirstTurn: { prompt, current, preparation in
            let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history,
                options: preparation.options, isCurrent: preparation.isCurrent)
            return (selected, h.selection.status)
        })
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence())
        let accessibleID = coordinator.currentID, signal = coordinator.newChatSignal
        chat.composer.draft = "Still accessible after New"
        let attachments = [AttachedDocument(name: "draft.txt", text: "Unsent attachment")]
        chat.composer.pendingDocuments = attachments
        var accepted = false
        let sending = Task { await chat.send(chat.composer.draft, documents: chat.composer.pendingDocuments, model: a,
            onAccepted: { accepted = true; chat.composer.draft = ""; chat.composer.pendingDocuments = [] }) }
        await gate.waitUntilReached()
        coordinator.startNew()
        XCTAssertEqual(coordinator.currentID, accessibleID, "An empty draft retains its reachable conversation identity")
        XCTAssertEqual(coordinator.newChatSignal, signal + 1)
        XCTAssertEqual(chat.composer.draft, "Still accessible after New")
        XCTAssertEqual(chat.composer.pendingDocuments, attachments)
        await gate.open()
        await sending.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.composer.draft, "Still accessible after New")
        XCTAssertEqual(chat.composer.pendingDocuments, attachments)
        XCTAssertEqual(coordinator.currentID, accessibleID)
        let loads = await raw.loads
        XCTAssertEqual(loads, [a.id])
        XCTAssertFalse(chat.isGenerating)
    }
}

extension AutomaticModelSelectionTests {
    func testContinueUsesPreparedPinRestorationAndCapturedContinuationHistory() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(a)); await raw.setProfile(profile(b))
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        let chat = ChatModel(engine: h.engine, admitTurn: { try h.onboarding.requireReadyForChat() },
            prepareFirstTurn: { prompt, current, preparation in
                let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history,
                    options: preparation.options, isCurrent: preparation.isCurrent)
                return (selected, h.selection.status)
            })
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence(), restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        await raw.setNextChatCapStatus(.hit)
        await chat.send("A capped answer", options: .init(maxTokens: 1), model: a)
        coordinator.persist()
        XCTAssertTrue(chat.lastHitTokenCap)
        XCTAssertEqual(coordinator.pinnedModelID, a.id)
        let original = chat.messages
        h.preferences.enabled = false
        try await h.engine.load(model: b, at: dir.appendingPathComponent(b.filename)) // Global selection changed elsewhere.
        h.preferences.enabled = true
        await chat.continueLast(options: .init(maxTokens: 32), model: b)
        let generated = await raw.generatedModelIDs, requests = await raw.profileRequests, loaded = await h.engine.loadedModelID()
        XCTAssertEqual(loaded, a.id)
        XCTAssertEqual(generated, [a.id, a.id])
        XCTAssertEqual(Array(chat.messages.prefix(original.count)), original)
        XCTAssertEqual(chat.messages.count, original.count + 2)
        XCTAssertEqual(chat.messages[original.count].text, ChatUserFacing.continueCue())
        XCTAssertTrue(requests.contains(where: { $0.count == original.count + 1 && $0.last?.text == ChatUserFacing.continueCue() }))
    }

    func testContinueRejectsPendingManualPreparationAndRemainsRetryableAfterCommit() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(a)); await raw.setProfile(profile(b))
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        let chat = ChatModel(engine: h.engine, admitTurn: { try h.onboarding.requireReadyForChat() },
            prepareFirstTurn: { prompt, current, preparation in
                let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history,
                    options: preparation.options, isCurrent: preparation.isCurrent)
                return (selected, h.selection.status)
            })
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence(), restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        await raw.setNextChatCapStatus(.hit)
        await chat.send("A capped answer", options: .init(maxTokens: 1), model: a)
        coordinator.persist()
        let original = chat.messages
        XCTAssertTrue(chat.lastHitTokenCap)
        let committed = SelectionGate()
        h.onboarding.onManualSelectionCommitted = { model in
            coordinator.chooseModelManually(model.id)
            Task { await committed.arriveAndWait() }
        }
        await raw.configure(block: b.id)
        h.onboarding.beginInstall(b)
        await raw.waitForBlockedLoad()
        h.preferences.enabled = true
        await chat.continueLast(options: .init(maxTokens: 32), model: a)
        let duringPreparation = await raw.generatedModelIDs
        XCTAssertEqual(duringPreparation, [a.id], "Continue cannot generate using the old model during a manual load")
        XCTAssertEqual(chat.messages, original)
        XCTAssertTrue(chat.lastHitTokenCap, "A rejected preparation must retain Continue for a later retry")
        XCTAssertNotNil(chat.preparationError)
        await raw.releaseLoad()
        await committed.waitUntilReached()
        await committed.open()
        await chat.continueLast(options: .init(maxTokens: 32), model: b)
        let generated = await raw.generatedModelIDs
        XCTAssertEqual(generated, [a.id, b.id])
        XCTAssertEqual(Array(chat.messages.prefix(original.count)), original)
        XCTAssertEqual(chat.messages[original.count].text, ChatUserFacing.continueCue())
    }
}

extension AutomaticModelSelectionTests {
    func testQueuedManualIntentBlocksSendAndContinueBeforeInitialModelQueryReturns() async throws {
        let dir = try directory(), a = try model("llama-a", directory: dir), b = try model("llama-b", directory: dir)
        let raw = SelectionFixtureEngine()
        await raw.setProfile(profile(a)); await raw.setProfile(profile(b))
        let h = try await harness(models: [a, b], current: a, directory: dir, raw: raw)
        let chat = ChatModel(engine: h.engine, admitTurn: { try h.onboarding.requireReadyForChat() },
            prepareFirstTurn: { prompt, current, preparation in
                let selected = try await h.selection.prepare(prompt: prompt, current: current, history: preparation.history,
                    options: preparation.options, isCurrent: preparation.isCurrent)
                return (selected, h.selection.status)
            })
        let coordinator = ConversationCoordinator(chat: chat, persistence: InMemoryConversationPersistence(), restoreSelectedModel: { id, preparation in
            try await h.onboarding.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
        })
        await raw.setNextChatCapStatus(.hit)
        await chat.send("A capped answer", options: .init(maxTokens: 1), model: a)
        coordinator.persist()
        let original = chat.messages
        XCTAssertTrue(chat.lastHitTokenCap)
        let initialQuery = SelectionGate(), committed = SelectionGate()
        h.onboarding.onManualSelectionCommitted = { model in
            coordinator.chooseModelManually(model.id)
            Task { await committed.arriveAndWait() }
        }
        await raw.blockNextModelQuery(initialQuery)
        h.onboarding.beginInstall(b)
        await initialQuery.waitUntilReached()
        XCTAssertFalse(h.onboarding.isInstalling, "Pause before install starts, not inside native loading")
        guard case .ready(let stillReady) = h.onboarding.phase else { return XCTFail("Old phase must still be ready in this queued window") }
        XCTAssertEqual(stillReady.id, a.id)
        XCTAssertThrowsError(try h.onboarding.requireReadyForChat())
        await chat.continueLast(options: .init(maxTokens: 32), model: a)
        var accepted = false
        await chat.send("Queued normal send", model: a, onAccepted: { accepted = true })
        XCTAssertFalse(accepted)
        XCTAssertEqual(chat.messages, original)
        XCTAssertTrue(chat.lastHitTokenCap)
        let generatedBeforeLoad = await raw.generatedModelIDs
        XCTAssertEqual(generatedBeforeLoad, [a.id])
        await initialQuery.open()
        await committed.waitUntilReached()
        await committed.open()
        XCTAssertNoThrow(try h.onboarding.requireReadyForChat(), "Matching terminal request must restore readiness")
        await chat.continueLast(options: .init(maxTokens: 32), model: b)
        let generatedAfterCommit = await raw.generatedModelIDs
        XCTAssertEqual(generatedAfterCommit, [a.id, b.id])
    }
}
