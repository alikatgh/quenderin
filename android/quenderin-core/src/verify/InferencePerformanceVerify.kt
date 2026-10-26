package ai.quenderin.core

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import ai.quenderin.app.AutomaticModelController

private const val PERFORMANCE_NOW = 1792800000000L
private fun performanceSample(id: String = "model-a", decodeMs: Double = 640.0, index: Int = 0) = InferencePerformanceSample(
    id, if (id == "model-a") "1".repeat(64) else "2".repeat(64), "a".repeat(64), "prism", "c".repeat(64),
    2048, 128, 128, 64, 120.0, decodeMs, 130.0, 10.0, 100.0, "cold", "nominal", PERFORMANCE_NOW - 1000 - index)
private fun performanceCandidate(id: String) = AutomaticModelCandidate(id,
    if (id == "model-a") "1".repeat(64) else "2".repeat(64), "a".repeat(64), "prism", "c".repeat(64),
    true, true, true, true, true, true, true, true)

private class AutomaticFixtureEngine : InferenceEngine {
    override var loadedModelId: String? = null
    val loads = mutableListOf<String>()
    var failure: String? = null
    var onLoad: (ModelEntry) -> Unit = {}
    var answer = "{\"answer\":\"fixture response\"}"
    var generationEntered: CountDownLatch? = null
    var generationRelease: CountDownLatch? = null
    var profiles: (ModelEntry, AutomaticChatRequest?, List<InferencePerformanceSample>) -> List<AutomaticExecutionProfile> = { _, _, _ -> emptyList() }
    override fun automaticExecutionProfiles(model: ModelEntry, prompt: AutomaticChatRequest?, observations: List<InferencePerformanceSample>) = profiles(model, prompt, observations)
    override fun pendingChatFits(model: ModelEntry, request: AutomaticChatRequest): Boolean {
        val profile = profiles(model, request, emptyList()).singleOrNull()
        val promptTokens = profile?.promptTokens
        return loadedModelId == model.id && (promptTokens == null || promptTokens + ChatTier.of(model).maxTokens <= profile.contextTokens)
    }
    override fun load(model: ModelEntry, filePath: String) {
        loads += model.id; loadedModelId = null; onLoad(model)
        check(model.id != failure) { "Fixture load failed" }
        loadedModelId = model.id
    }
    override fun unload() { loadedModelId = null }
    override fun complete(prompt: String): String {
        generationEntered?.countDown(); check(generationRelease?.await(3, TimeUnit.SECONDS) != false)
        return answer
    }
}

private fun verifyPerformanceStorage(root: File) {
    val path = File(root, "performance-store.bin")
    val store = InferencePerformanceStore(path) { PERFORMANCE_NOW }
    val good = performanceSample()
    check(store.record(good)); check(store.record(good)); check(store.samples() == listOf(good))
    for (bad in listOf(good.copy(decodeMs = Double.NaN), good.copy(loadMs = Double.POSITIVE_INFINITY),
        good.copy(firstTokenMs = -1.0), good.copy(decodedTokens = 31), good.copy(promptTokens = 0),
        good.copy(modelID = "private prompt with spaces"), good.copy(modelID = "a".repeat(257)),
        good.copy(artifactSHA256 = "unknown"), good.copy(backendID = "max"),
        good.copy(recordedAtMs = PERFORMANCE_NOW + 1), good.copy(recordedAtMs = PERFORMANCE_NOW - InferencePerformanceSample.MAX_AGE_MS - 1))) {
        val before = path.readBytes(); check(!store.record(bad)); check(path.readBytes().contentEquals(before))
    }
    repeat(100) { check(store.record(performanceSample(index = it))) }
    check(store.samples().size == 64 && path.length() <= 131072)
    check(store.samples().first().recordedAtMs == PERFORMANCE_NOW - 1000)
    val bytes = path.readBytes()
    check(!bytes.toString(Charsets.ISO_8859_1).contains("private prompt"))
    check(InferencePerformanceStore(path) { PERFORMANCE_NOW + InferencePerformanceSample.MAX_AGE_MS + 1 }.samples().isEmpty())
    path.writeBytes(byteArrayOf(1, 2, 3)); check(store.samples().isEmpty())
    path.writeBytes(ByteArray(131073)); check(store.samples().isEmpty())
    check(store.record(good) && store.samples() == listOf(good))
    // An unwritable destination cannot break chat or remove its existing contents.
    val directory = File(root, "blocked-store").also { check(it.mkdir()) }
    val marker = File(directory, "marker").also { it.writeText("retained") }
    check(!InferencePerformanceStore(directory) { PERFORMANCE_NOW }.record(good)); check(marker.readText() == "retained")
    check(directory.listFiles()!!.size == 1)
    check(marker.delete()); check(directory.delete()); check(path.delete())
    println("PASS: numeric bounded atomic performance storage rejects corruption, stale/invalid reports and duplicate replay")
}

private fun verifyAutomaticModeAndOwnership() {
    var persisted = false
    val mode = AutomaticSelectionMode({ persisted }, { persisted = it })
    check(!mode.enabled()); mode.setEnabled(true)
    check(AutomaticSelectionMode({ persisted }).enabled())
    val oldTicket = mode.ticket()!!; mode.manualChoice()
    check(!mode.enabled() && !mode.current(oldTicket) && !AutomaticSelectionMode({ persisted }).enabled())
    mode.setEnabled(true)
    var now = PERFORMANCE_NOW
    val selector = AutomaticTurnSelection(mode) { now }
    val candidates = listOf(performanceCandidate("model-a"), performanceCandidate("model-b"))
    val samples = (0..2).flatMap { listOf(performanceSample(index = it), performanceSample("model-b", 100.0, it)) }
    var attempts = 0
    fun prepare(first: Boolean = true, activate: (String, () -> Boolean) -> Boolean = { _, _ -> attempts++; false }) =
        selector.prepare(first, "model-a", candidates, samples, 128, 64, 2048, activate = activate)
    check(prepare(first = false) == null && attempts == 0)
    check(prepare() == null && attempts == 1)
    check(prepare()?.modelID == "model-a" && attempts == 1) // bounded failure cooldown
    now += 600_001; check(prepare() == null && attempts == 2)
    now += 600_001
    check(prepare { _, isCurrent -> mode.manualChoice(); check(!isCurrent()); true } == null)
    check(!persisted)

    val a = ModelCatalog.entry("llama32-1b")!!; val b = ModelCatalog.entry("llama32-3b")!!
    val raw = AutomaticFixtureEngine(); val engine = CoordinatedInferenceEngine(raw)
    engine.load(a, "/fixture-a.gguf")
    var networkCalls = 0
    val downloader = object : ModelDownloader {
        override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String { networkCalls++; error("Automatic reached a downloader") }
    }
    var savedID: String? = a.id
    val loader = OnboardingModel(engine, downloader, rememberActiveModelID = { savedID = it },
        verifiedInstalledPath = { if (it.id == a.id) "/fixture-a.gguf" else "/fixture-b.gguf" })
    raw.failure = b.id
    check(!loader.activateInstalled(b)); check(engine.loadedModelId == a.id && savedID == a.id && networkCalls == 0)
    check(raw.loads == listOf(a.id, b.id, a.id)) // one switch plus one recovery
    raw.failure = null
    val before = raw.loads.size
    check(!OnboardingModel(engine, downloader).activateInstalled(b)); check(raw.loads.size == before && networkCalls == 0)
    mode.setEnabled(true)
    val ticket = mode.ticket()!!
    raw.onLoad = { if (it.id == b.id) mode.manualChoice() }
    check(!loader.activateInstalled(b) { mode.current(ticket) }); check(engine.loadedModelId == a.id && !mode.enabled())
    raw.onLoad = {}
    val guard = engine.preventAutomaticModelSwitch()
    check(!engine.automaticSelectionIdle)
    val heldLoads = raw.loads.size
    check(!loader.activateInstalled(b) && raw.loads.size == heldLoads)
    guard.close(); guard.close(); check(engine.automaticSelectionIdle)

    // No wait-and-switch: active generation remains uninterrupted and keeps its native owner.
    raw.generationEntered = CountDownLatch(1); raw.generationRelease = CountDownLatch(1)
    val worker = thread { engine.complete("fixture") }
    check(raw.generationEntered!!.await(2, TimeUnit.SECONDS))
    check(!loader.activateInstalled(b) && engine.loadedModelId == a.id)
    raw.generationRelease!!.countDown(); worker.join(2000); check(!worker.isAlive)
    raw.generationEntered = null; raw.generationRelease = null
    check(loader.activateInstalled(b) && engine.loadedModelId == b.id && networkCalls == 0)

    // Agent holds survive onChange/tool gaps, and are released for success, cancellation and errors.
    engine.load(a, "/fixture-a.gguf")
    val session = AgentSession(engine, emptyList())
    var sawHold = false
    session.onChange = { if (session.isRunning) { sawHold = true; check(!engine.automaticSelectionIdle); check(!loader.activateInstalled(b)) } }
    session.run("fixture answer"); check(sawHold && engine.automaticSelectionIdle)
    session.onChange = { if (session.isRunning) { check(!engine.automaticSelectionIdle); session.cancel() } }
    session.run("fixture cancellation"); check(engine.automaticSelectionIdle && !session.isRunning)
    session.onChange = { if (session.isRunning) error("Fixture callback failure") }
    runCatching { session.run("fixture failure") }; check(engine.automaticSelectionIdle && !session.isRunning)
    for (throwTool in listOf(false, true)) {
        var enteredTool = false
        val tool = object : AgentTool {
            override val name = "fixture-tool"
            override val purpose = "Local host fixture"
            override fun run(input: String): String {
                enteredTool = true
                check(!engine.automaticSelectionIdle && !loader.activateInstalled(b))
                raw.answer = "{\"answer\":\"fixture response\"}"
                if (throwTool) error("Fixture tool failure")
                return "fixture observation"
            }
        }
        raw.answer = "{\"tool\":\"fixture-tool\",\"input\":\"fixture\"}"
        val toolsSession = AgentSession(engine, listOf(tool))
        toolsSession.run("fixture workflow")
        check(enteredTool && !toolsSession.isRunning && engine.automaticSelectionIdle && engine.loadedModelId == a.id)
    }
    println("PASS: explicit mode, manual invalidation, cooldown, offline switch/recovery and ordinary/agent ownership")
}

private fun verifySharedPerformanceFixtures(file: File) {
    val document = RemoteHarnessJSON.parse(file.readBytes()).objectValue()
    check(document.getValue("schemaVersion").integerValue() == 1L)
    val cases = (document.getValue("cases") as RemoteHarnessJSON.ArrayValue).values
    val names = HashSet<String>()
    for (caseValue in cases) {
        val c = caseValue.objectValue()
        fun s(key: String) = c.getValue(key).stringValue()
        fun i(key: String) = c.getValue(key).integerValue().toInt()
        val candidates = (c.getValue("candidates") as RemoteHarnessJSON.ArrayValue).values.map { row ->
            val m = row.objectValue()
            fun v(key: String) = m.getValue(key).stringValue()
            fun b(key: String) = m.getValue(key).booleanValue()
            AutomaticModelCandidate(v("modelID"), v("artifactSHA256"), v("runtimeID"), v("backendID"), v("environmentID"),
                b("installed"), b("verified"), b("runtimeAvailable"), b("fitsMemory"), b("fitsContext"), b("fitsDisk"), b("supportsTask"), b("qualityEligible"),
                cacheMode = m["cacheMode"]?.stringValue())
        }
        val samples = (c.getValue("samples") as RemoteHarnessJSON.ArrayValue).values.map { row ->
            val m = row.objectValue()
            fun v(key: String) = m.getValue(key).stringValue()
            fun n(key: String) = (m.getValue(key) as RemoteHarnessJSON.NumberValue).token.toDouble()
            fun x(key: String) = n(key).toInt()
            InferencePerformanceSample(v("modelID"), v("artifactSHA256"), v("runtimeID"), v("backendID"), v("environmentID"),
                x("contextTokens"), x("promptTokens"), x("prefillTokens"), x("decodedTokens"), n("prefillMs"), n("decodeMs"), n("firstTokenMs"),
                n("maxGapMs"), n("loadMs"), v("cacheMode"), v("thermalState"), m.getValue("recordedAtMs").integerValue())
        }
        val currentID = c["currentID"]?.takeUnless { it === RemoteHarnessJSON.NullValue }?.stringValue()
        val decision = MeasuredAutomaticPolicy.choose(currentID, candidates, samples, i("promptTokens"), i("expectedOutputTokens"),
            i("contextTokens"), s("cacheMode"), c.getValue("nowMs").integerValue())
        check(decision?.modelID == s("expectedModelID")) { "Performance fixture failed: ${s("name")}: ${decision?.modelID}" }
        c["expectedObserved"]?.let { check(decision?.observed == it.booleanValue()) { "Performance fixture evidence failed: ${s("name")}" } }
        val name = s("name"); check(names.add(name))
        println("INFERENCE_PERFORMANCE_FIXTURE_PASS $name")
    }
}

private fun verifyAppSelectionFlow(root: File) {
    val models = File(root, "controller-models").also { check(it.mkdir()) }
    val a = ModelCatalog.entry("llama32-3b")!!
    val b = ModelCatalog.entry("llama3-8b")!!
    val paths = listOf(a, b).associate { it.id to File(models, it.filename).also { file -> file.writeText("GGUFfixture") }.absolutePath }
    val raw = AutomaticFixtureEngine(); val engine = CoordinatedInferenceEngine(raw)
    var scans = 0; var clock = 0L; var wallClock = PERFORMANCE_NOW
    val receipts = ModelArtifactVerificationReceipts(verifyBytes = { _, path ->
        scans++; clock += 250_000_000
        ModelIntegrity.hasGGUFMagic(JvmFileSink().head(path, 4))
    }, nanoTime = { clock })
    fun proof(model: ModelEntry) = receipts.verify(model, paths.getValue(model.id))?.path
    check(proof(a) != null)
    raw.onLoad = { check(proof(it) != null) } // The concrete engine also checks the same receipt.
    engine.load(a, paths.getValue(a.id))
    check(scans == 1)
    var automatic = false; var manualID = a.id
    val mode = AutomaticSelectionMode({ automatic }, { automatic = it })
    val downloader = object : ModelDownloader {
        var calls = 0
        override fun needsFetch(model: ModelEntry) = false
        override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String { calls++; return paths.getValue(model.id) }
    }
    val onboarding = OnboardingModel(engine, downloader, verifiedInstalledPath = ::proof)
    var thermal = ThermalLevel.NOMINAL
    var changedEnvironment = false
    var fallbackContext = false
    var targetPromptOverflows = false
    var observedTargetRequest: AutomaticChatRequest? = null
    fun profile(model: ModelEntry): AutomaticExecutionProfile = AutomaticExecutionProfile("a".repeat(64), "prism",
        (if (model.id == a.id) if (changedEnvironment) "e" else "c" else if (fallbackContext) "f" else "d").repeat(64),
        if (model.id == b.id && fallbackContext) 1024 else 2048, thermal, if (model.id == a.id) "prefix" else "cold", 128)
    raw.profiles = { model, request, _ ->
        if (model.id == b.id && request != null) observedTargetRequest = request
        listOf(profile(model).let { if (model.id == b.id && request != null && targetPromptOverflows) it.copy(promptTokens = 1900) else it })
    }
    val historyFile = File(root, "controller-performance.bin")
    val store = InferencePerformanceStore(historyFile) { PERFORMANCE_NOW }
    for (index in 0..2) {
        check(store.record(performanceSample(index = index).copy(modelID = a.id, artifactSHA256 = InferencePerformanceIdentity.artifact(a)!!,
            cacheMode = "prefix", prefillTokens = 64)))
        check(store.record(performanceSample("model-b", 40.0, index).copy(modelID = b.id,
            artifactSHA256 = InferencePerformanceIdentity.artifact(b)!!, environmentID = "d".repeat(64))))
    }
    val controller = AutomaticModelController(engine, onboarding, mode, store, models,
        { AndroidDeviceProfile("fixture", AndroidSoc.SNAPDRAGON_8_ELITE, 64.0, 48.0, 100.0, 4500.0) },
        { model, prompt, observations -> engine.automaticExecutionProfiles(model, prompt, observations) },
        rememberManualModel = { manualID = it }, receipts = receipts, now = { wallClock })
    controller.setAutomaticEnabled(true)
    val downloaderCalls = downloader.calls
    check(controller.prepare("fixture", true, false)?.id == b.id)
    check(engine.loadedModelId == b.id && scans == 2 && downloader.calls == downloaderCalls)
    check(controller.description.contains(b.label) && controller.description.contains("Observed speed"))
    controller.setAutomaticEnabled(false)
    check(controller.captureTurnIntent().requiredManualModelID == b.id && controller.acceptsTurnIntent(controller.captureTurnIntent()))
    controller.setAutomaticEnabled(true)
    // Explicitly picking the already-current B persists B immediately and still confirms through the loader.
    val loads = raw.loads.size
    controller.manualChoice(b); check(manualID == b.id && !automatic)
    controller.confirmManualChoice(b); check(raw.loads.size == loads + 1 && engine.loadedModelId == b.id)
    check(AutomaticSelectionMode({ automatic }).enabled() == false && manualID == b.id)
    check(controller.description.contains(b.label) && controller.description.contains("Estimated speed"))
    controller.manualChoice(a); controller.confirmManualChoice(a); controller.setAutomaticEnabled(true)
    check(controller.prepare("later turn", false, false)?.id == a.id)
    check(controller.description.contains(a.label) && !controller.description.contains(b.label) && controller.description.contains("Estimated speed"))
    check(controller.prepare("document turn", true, true)?.id == a.id)
    check(controller.description.contains("Estimated speed"))
    thermal = ThermalLevel.FAIR; check(controller.prepare("hot turn", true, false)?.id == a.id)
    check(controller.description.contains("Estimated speed")); thermal = ThermalLevel.NOMINAL
    changedEnvironment = true; check(controller.prepare("changed driver/config", true, false)?.id == a.id)
    check(controller.description.contains("Estimated speed")); changedEnvironment = false
    val hold = engine.preventAutomaticModelSwitch()
    check(controller.prepare("active agent", true, false)?.id == a.id && controller.description.contains(a.label))
    hold.close()

    // The unloaded candidate cannot borrow A's tokenizer count. B's actual loaded template/prompt
    // expands beyond the same 2048 window and must be rejected before accepting the switch.
    targetPromptOverflows = true
    val multilingual = AutomaticChatRequest("日本語と한국어とкириллица", history = listOf(ChatMessage(Role.USER, "guided context"), ChatMessage(Role.ASSISTANT, "guided reply")))
    val beforeOverflowLoads = raw.loads.size
    check(controller.prepare(multilingual.text, true, false, request = multilingual)?.id == a.id)
    check(engine.loadedModelId == a.id && observedTargetRequest == multilingual && raw.loads.drop(beforeOverflowLoads) == listOf(b.id, a.id))
    targetPromptOverflows = false
    wallClock += 600_001 // The rejected oversized target has a bounded failure cooldown.

    // A same-ID manual tap during awaiting B invalidates Automatic, recovers A once, then queued manual B wins.
    raw.onLoad = { model -> check(proof(model) != null); if (model.id == b.id) controller.manualChoice(b) }
    runCatching { controller.prepare("manual wins", true, false) }.onSuccess { error("Stale preparation was accepted") }
    check(engine.loadedModelId == a.id && manualID == b.id && !automatic)
    raw.onLoad = { check(proof(it) != null) }; controller.confirmManualChoice(b)
    check(engine.loadedModelId == b.id && manualID == b.id && scans == 2)
    // The UI has requested A, but its loader confirmation is still queued. A Send gesture must
    // capture the pending intent synchronously rather than take B's loaded ID as confirmation.
    val pendingA = controller.manualChoice(a)
    val pendingTurn = controller.captureTurnIntent()
    check(!pendingTurn.ready && !controller.acceptsTurnIntent(pendingTurn) && engine.loadedModelId == b.id)
    check(runCatching { controller.prepare("must not use B", false, false) }.isFailure)
    controller.confirmManualChoice(pendingA)
    val confirmedTurn = controller.captureTurnIntent()
    check(confirmedTurn.ready && confirmedTurn.requiredManualModelID == a.id && controller.acceptsTurnIntent(confirmedTurn))
    raw.failure = b.id
    val failingB = controller.manualChoice(b)
    controller.confirmManualChoice(failingB)
    val recoveredA = controller.captureTurnIntent()
    check(recoveredA.ready && recoveredA.requiredManualModelID == a.id && controller.acceptsTurnIntent(recoveredA))
    check(engine.loadedModelId == a.id && manualID == b.id && controller.manualPreparationMessage!!.contains(a.label))
    val recoveredChat = ChatModel(engine)
    check(recoveredChat.withSelectedModel(a.id) { recoveredChat.send("use recovered A", model = a, admission = recoveredChat.captureTurnAdmission()) }.isNotEmpty())
    controller.setAutomaticEnabled(true); check(automatic && controller.manualPreparationMessage == null)
    raw.failure = null

    // Conversation pins survive A/X -> B/Y -> reopen A, including index round-trip/relaunch.
    val persistenceDir = File(root, "pinned-conversations")
    val persistence = FileConversationPersistence(persistenceDir)
    var nextID = 0
    val coordinator = ConversationCoordinator(ChatModel(engine), persistence, now = { PERFORMANCE_NOW }, makeId = { "fixture-${++nextID}" })
    check(!coordinator.hasOrdinaryTurn)
    coordinator.chat.recordGuidedTurn("computer task", emptyList(), "guided only")
    coordinator.persist(); check(!coordinator.hasOrdinaryTurn) // Guided messages do not consume Automatic's first ordinary turn.
    val firstID = coordinator.currentId!!
    coordinator.pinLocalModel(a.id); coordinator.chat.recordGuidedTurn("first", emptyList(), "fixture")
    coordinator.persist(); coordinator.startNew()
    coordinator.pinLocalModel(b.id); coordinator.chat.recordGuidedTurn("second", emptyList(), "fixture")
    coordinator.persist(); coordinator.open(firstID)
    check(coordinator.pinnedLocalModelID == a.id)
    controller.setAutomaticEnabled(true)
    check(controller.restorePinned(coordinator.pinnedLocalModelID!!) { true }?.id == a.id)
    check(engine.loadedModelId == a.id)
    val restored = ConversationCoordinator(ChatModel(engine), FileConversationPersistence(persistenceDir))
    restored.open(firstID); check(restored.pinnedLocalModelID == a.id)
    check(restored.hasOrdinaryTurn)
    val stickyRequest = AutomaticChatRequest(multilingual.text, history = coordinator.chat.messages,
        documents = listOf(AttachedDocument("context.txt", "retained conversation attachment")))
    targetPromptOverflows = true
    check(runCatching { controller.restorePinned(b.id, stickyRequest) { true } }.isFailure)
    check(engine.loadedModelId == a.id && observedTargetRequest == stickyRequest)
    check(observedTargetRequest!!.history == coordinator.chat.messages && observedTargetRequest!!.documents.single().name == "context.txt")
    targetPromptOverflows = false
    check(controller.restorePinned(b.id, stickyRequest) { true }?.id == b.id)
    targetPromptOverflows = true
    val alreadyLoadedCount = raw.loads.size
    check(runCatching { controller.restorePinned(b.id, stickyRequest) { true } }.isFailure)
    check(raw.loads.size == alreadyLoadedCount) // Even an already-loaded sticky target validates the full pending history.
    targetPromptOverflows = false
    check(controller.restorePinned(a.id) { true }?.id == a.id)
    val legacyDir = File(root, "legacy-conversation").also { check(it.mkdir()) }
    val legacyPersistence = FileConversationPersistence(legacyDir)
    legacyPersistence.saveTranscript("legacy", listOf(ChatMessage(Role.USER, "legacy text")))
    File(legacyDir, "index.tsv").writeText("legacy\tLegacy\t$PERFORMANCE_NOW\tpreview\t${b.id}")
    val legacy = ConversationCoordinator(ChatModel(engine), legacyPersistence)
    check(legacy.pinnedLocalModelID == null && legacy.hasOrdinaryTurn) // Old labels/pins cannot become Automatic authority.
    legacyDir.listFiles()!!.forEach { check(it.delete()) }; check(legacyDir.delete())
    // Empty New Chat is still a lifecycle invalidation, even while no user turn has been appended.
    val empty = ConversationCoordinator(ChatModel(engine), InMemoryConversationPersistence())
    val revision = empty.lifecycleRevision
    wallClock += 600_001 // The earlier intentionally superseded B attempt has a bounded cooldown.
    raw.onLoad = { model -> check(proof(model) != null); if (model.id == b.id) empty.startNew() }
    controller.prepare("new chat invalidates", true, false) { empty.lifecycleRevision == revision }
    check(empty.lifecycleRevision != revision && empty.chat.messages.isEmpty() && engine.loadedModelId == a.id)
    raw.onLoad = { check(proof(it) != null) }
    // Post-load effective context/KV fallback must match the admitted profile before accepting B.
    val expectedB = profile(b)
    fallbackContext = true
    check(!onboarding.activateInstalled(b, expectedProfile = expectedB))
    check(engine.loadedModelId == a.id); fallbackContext = false
    // A manual load in the UI scheduling gap cannot cause send() to run with another model's options.
    engine.load(b, paths.getValue(b.id))
    var enteredStaleSend = false
    check(runCatching { coordinator.chat.withSelectedModel(a.id) { enteredStaleSend = true } }.isFailure && !enteredStaleSend)
    // Continue uses the same actual app preparation as Send: an Auto pin restores A from B,
    // appends one existing continuation cue, and leaves the unrelated composer draft untouched.
    controller.setAutomaticEnabled(true)
    val continuationCue = ChatUserFacing.continueCue("en")
    val continuationHistory = coordinator.chat.messages
    val continuationRequest = AutomaticChatRequest(continuationCue, history = continuationHistory)
    coordinator.saveDraft(coordinator.currentId, "unrelated composer draft", listOf(AttachedDocument("later.txt", "later attachment")))
    val continuationDraft = coordinator.draft(coordinator.currentId)
    val continuationIntent = controller.captureTurnIntent()
    val continuation = controller.prepareTurn(continuationRequest, false, false, a.id, continuationIntent) { true }!!
    check(continuation.model.id == a.id && continuation.accepts() && engine.loadedModelId == a.id)
    val continuationAdmission = coordinator.chat.captureTurnAdmission(continuation.accepts)
    coordinator.chat.withSelectedModel(continuation.model.id) {
        coordinator.chat.send(continuationCue, model = continuation.model, admission = continuationAdmission,
            onAdmitted = { coordinator.recordLocalAdmission(continuation.model.id, true, coordinator.currentId) })
    }
    check(coordinator.chat.messages.size == continuationHistory.size + 2 && coordinator.chat.messages.count { it.role == Role.USER && it.text == continuationCue } == 1)
    check(coordinator.draft(coordinator.currentId) == continuationDraft)
    val queuedContinuationTarget = controller.manualChoice(b)
    val blockedContinuationIntent = controller.captureTurnIntent()
    val blockedMessageCount = coordinator.chat.messages.size
    val blockedLoadCount = raw.loads.size
    check(!blockedContinuationIntent.ready && runCatching {
        controller.prepareTurn(AutomaticChatRequest(continuationCue, history = coordinator.chat.messages), false, false, a.id, blockedContinuationIntent) { true }
    }.isFailure)
    check(coordinator.chat.messages.size == blockedMessageCount && raw.loads.size == blockedLoadCount)
    controller.confirmManualChoice(queuedContinuationTarget); controller.setAutomaticEnabled(true)

    // 31 minutes of idle time cannot force an unpriced rollback scan of unchanged A.
    val oldAProof = receipts.current(a, paths.getValue(a.id))!!
    val scansBeforeClockAdvance = scans
    clock += 1_800_000_000_001L
    check(receipts.current(a, paths.getValue(a.id)) == oldAProof && proof(a) != null && proof(b) != null)
    check(scans == scansBeforeClockAdvance)

    // A changed artifact stamp requires one new full verification; unchanged paths never rehash.
    val beforeScans = scans
    File(paths.getValue(a.id)).appendText("changed")
    check(receipts.current(a, paths.getValue(a.id)) == null && proof(a) != null && scans == beforeScans + 1)
    check(proof(a) != null && scans == beforeScans + 1)
    // Policy must debit verification time rather than treating native load as the complete switch cost.
    val expensive = performanceCandidate("model-b").copy(switchCostFloorMs = 100_000.0)
    val numericRows = (0..2).flatMap { listOf(performanceSample(index = it), performanceSample("model-b", 40.0, it)) }
    check(MeasuredAutomaticPolicy.choose("model-a", listOf(performanceCandidate("model-a"), expensive), numericRows,
        128, 64, 2048, "cold", PERFORMANCE_NOW)?.modelID == "model-a")
    // Independent real SHA receipt test: mutation fails the expected publisher digest.
    val realFile = File(root, "receipt.gguf").also { it.writeText("GGUFreal-hash") }
    val realModel = a.copy(filename = realFile.name, sha256 = ModelIntegrity.sha256Hex(realFile), downloadBytes = realFile.length(), artifacts = emptyList())
    val realReceipts = ModelArtifactVerificationReceipts()
    check(realReceipts.verify(realModel, realFile.path) != null)
    realFile.appendText("tampered"); check(realReceipts.verify(realModel, realFile.path) == null)
    check(realFile.delete()); check(historyFile.delete())
    // Missing remembered A -> an explicit recovery/setup choice of B uses the same intent path;
    // the new persisted choice, not stale A, is restored on the next launch.
    check(File(paths.getValue(a.id)).delete()); manualID = a.id
    val setupB = controller.manualChoice(b); check(manualID == b.id)
    controller.confirmManualChoice(setupB)
    val relaunched = OnboardingModel(engine, downloader, recallActiveModelID = { manualID },
        activeModelFileExists = { File(paths.getValue(it.id)).isFile })
    check(relaunched.restoreAtLaunch() && (relaunched.phase as OnboardingPhase.Ready).model.id == b.id)
    paths.values.forEach { if (it != paths.getValue(a.id)) check(File(it).delete()) }; check(models.delete())
    // These are fixture-only transcripts/index files created above, never user history.
    persistenceDir.listFiles()!!.forEach { check(it.delete()) }; check(persistenceDir.delete())
    println("PASS: actual app controller manual persistence, fresh labels, one SHA receipt/cost debit, sticky models and lifecycle/configuration races")
}

private fun verifyLifecycleTurnAdmission() {
    val a = ModelCatalog.entry("llama32-3b")!!
    val raw = AutomaticFixtureEngine(); val engine = CoordinatedInferenceEngine(raw)
    engine.load(a, "/fixture-a.gguf")
    val backing = InMemoryConversationPersistence()
    val enteredIndex = CountDownLatch(1); val releaseIndex = CountDownLatch(1)
    val blockNextIndex = AtomicBoolean(false)
    val persistence = object : ConversationPersistence by backing {
        override fun saveIndex(summaries: List<ConversationSummary>) {
            if (blockNextIndex.compareAndSet(true, false)) {
                enteredIndex.countDown(); check(releaseIndex.await(3, TimeUnit.SECONDS))
            }
            backing.saveIndex(summaries)
        }
    }
    var id = 0
    val coordinator = ConversationCoordinator(ChatModel(engine), persistence, makeId = { "admission-${++id}" })
    val chat = coordinator.chat
    chat.recordGuidedTurn("existing", emptyList(), "existing reply"); coordinator.persist()
    val originalID = coordinator.currentId
    val attachment = AttachedDocument("draft-a.txt", "draft A attachment")
    coordinator.saveDraft(originalID, "draft A", listOf(attachment))
    val originalRevision = coordinator.lifecycleRevision
    val admission = chat.captureTurnAdmission { coordinator.currentId == originalID && coordinator.lifecycleRevision == originalRevision }
    val queuedFrames = java.util.Collections.synchronizedList(mutableListOf<Pair<Long, List<ChatMessage>>>())
    val queuedPhases = java.util.Collections.synchronizedList(mutableListOf<Pair<Long, GenerationPhase>>())
    chat.onRevisionChange = { revision, messages -> queuedFrames += revision to messages }
    chat.onRevisionPhaseChange = { revision, phase -> queuedPhases += revision to phase }
    var nativeCalls = 0
    raw.generationEntered = CountDownLatch(1)
    raw.onLoad = {}
    // A real accepted turn enters index persistence after atomic transcript admission. New Chat
    // can reset it while the filesystem call is blocked, without waiting on the generation lock.
    blockNextIndex.set(true)
    val failure = AtomicReference<Throwable?>()
    val worker = thread {
        try { chat.withSelectedModel(a.id) { chat.send("outgoing turn", model = a, admission = admission,
            onAdmitted = { coordinator.recordLocalAdmission(a.id, true, originalID) }) } }
        catch (error: Throwable) { failure.set(error) }
    }
    check(enteredIndex.await(2, TimeUnit.SECONDS))
    val newFinished = CountDownLatch(1)
    val newChat = thread { try { coordinator.startNew() } finally { newFinished.countDown() } }
    val lifecycleDidNotWaitOnIO = newFinished.await(500, TimeUnit.MILLISECONDS)
    releaseIndex.countDown(); worker.join(2000); newChat.join(2000)
    check(lifecycleDidNotWaitOnIO && !worker.isAlive && !newChat.isAlive && failure.get() == null)
    check(raw.generationEntered!!.count == 1L) // completeChat never started/reset native cancellation.
    check(backing.loadTranscript(originalID!!).map { it.role to it.text } == listOf(
        Role.USER to "existing", Role.ASSISTANT to "existing reply", Role.USER to "outgoing turn",
    )) // Navigation removes only the unfinished assistant, retaining the prior exchange and outgoing user.
    check(backing.loadIndex().single().let {
        it.id == originalID && it.preview == ConversationLibrary.youPrefix() + "outgoing turn"
    }) // Blocked old metadata cannot overwrite the newer saved user-turn preview.
    check(chat.messages.isEmpty() && !chat.isGenerating && chat.generationPhase == GenerationPhase.IDLE && !chat.lastHitTokenCap)
    check(queuedFrames.filter { chat.isRevisionCurrent(it.first) }.all { it.second.isEmpty() })
    check(queuedPhases.filter { chat.isRevisionCurrent(it.first) }.all { it.second == GenerationPhase.IDLE })
    check(runCatching { chat.send("stale admission", model = a, admission = admission) }.isFailure)
    check(chat.messages.isEmpty())
    val idleStopChat = ChatModel(engine)
    val beforeStopAdmission = idleStopChat.captureTurnAdmission()
    idleStopChat.stopGenerating() // The actual Stop path must invalidate even before isGenerating becomes true.
    check(runCatching { idleStopChat.withSelectedModel(a.id) {
        idleStopChat.send("synchronous IO after Stop", model = a, admission = beforeStopAdmission)
    } }.isFailure)
    check(idleStopChat.messages.isEmpty() && raw.generationEntered!!.count == 1L)
    val newID = coordinator.currentId
    check(newID != originalID && coordinator.draft(newID) == ConversationDraft())
    coordinator.saveDraft(newID, "draft B", emptyList())
    coordinator.open(originalID!!)
    check(coordinator.draft(coordinator.currentId) == ConversationDraft("draft A", listOf(attachment)))
    coordinator.open(newID!!)
    check(coordinator.draft(coordinator.currentId) == ConversationDraft("draft B", emptyList()))
    coordinator.saveDraft(coordinator.currentId, "Stop preserves this draft", listOf(attachment))
    val stopID = coordinator.currentId
    val stopRevision = coordinator.lifecycleRevision
    val stopCount = chat.messages.size
    var visibleTextAfterStop = ""
    var visibleDocumentsAfterStop = emptyList<AttachedDocument>()
    coordinator.draftAfterCancelledAdmission(stopID, stopRevision, stopCount)?.let {
        visibleTextAfterStop = it.text; visibleDocumentsAfterStop = it.documents
    }
    check(visibleTextAfterStop == "Stop preserves this draft" && visibleDocumentsAfterStop == listOf(attachment))
    val emptyID = coordinator.currentId
    val emptyRevision = coordinator.lifecycleRevision
    val emptyAdmission = chat.captureTurnAdmission()
    coordinator.startNew()
    check(coordinator.currentId == emptyID && coordinator.lifecycleRevision != emptyRevision)
    check(coordinator.draft(coordinator.currentId) == ConversationDraft("Stop preserves this draft", listOf(attachment)))
    check(coordinator.draftAfterCancelledAdmission(stopID, stopRevision, stopCount) == null) // A stale Stop completion cannot overwrite edits after New.
    check(runCatching { chat.send("stale empty-chat preparation", model = a, admission = emptyAdmission) }.isFailure)
    check(chat.messages.isEmpty())

    // A backend may deliver callbacks and return a full answer after cancellation. None of its
    // stale phase/cap/text events can overwrite reset/restore or a queued UI frame for the new chat.
    val nativeEntered = CountDownLatch(1); val nativeRelease = CountDownLatch(1)
    val late = object : InferenceEngine {
        override val loadedModelId = a.id
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String) = "late"
        override fun lastHitTokenCap() = true
        override fun completeChatOwned(systemPrompt: String, history: List<ChatMessage>, isCurrent: () -> Boolean, onToken: (String) -> Unit): String {
            nativeCalls++; check(isCurrent()); nativeEntered.countDown(); check(nativeRelease.await(3, TimeUnit.SECONDS))
            onToken("late token"); return "late authoritative answer"
        }
    }
    val lateChat = ChatModel(late)
    val lateCoordinator = ConversationCoordinator(lateChat, InMemoryConversationPersistence())
    val staleCleanupID = lateCoordinator.currentId
    val staleCleanupRevision = lateCoordinator.lifecycleRevision
    lateCoordinator.startNew()
    val lateFrames = java.util.Collections.synchronizedList(mutableListOf<Pair<Long, List<ChatMessage>>>())
    val latePhases = java.util.Collections.synchronizedList(mutableListOf<Pair<Long, GenerationPhase>>())
    lateChat.onRevisionChange = { revision, messages -> lateFrames += revision to messages }
    lateChat.onRevisionPhaseChange = { revision, phase -> latePhases += revision to phase }
    val lateWorker = thread { lateChat.send("old turn", model = a, admission = lateChat.captureTurnAdmission()) }
    check(nativeEntered.await(2, TimeUnit.SECONDS))
    check(!lateCoordinator.persistIfOwned(staleCleanupID, staleCleanupRevision) { true })
    check(!lateCoordinator.persistIfOwned(lateCoordinator.currentId, lateCoordinator.lifecycleRevision) { false })
    check(lateChat.isGenerating) // Neither stale-lifecycle nor stale-job cleanup may stop the new owner.
    val oldUIJob = Any(); val replacementUIJob = Any()
    var uiOwner: Any? = oldUIJob; var uiBusy = true
    lateCoordinator.finishOwnedSend(staleCleanupID, staleCleanupRevision, { uiOwner === oldUIJob }) { uiOwner = null; uiBusy = false }
    check(!uiBusy && uiOwner == null && lateChat.isGenerating) // New invalidates persistence, while the matching old UI owner still settles.
    uiOwner = replacementUIJob; uiBusy = true
    lateCoordinator.finishOwnedSend(staleCleanupID, staleCleanupRevision, { uiOwner === oldUIJob }) { uiOwner = null; uiBusy = false }
    check(uiBusy && uiOwner === replacementUIJob && lateChat.isGenerating) // Old cleanup cannot clear a replacement send's controls.
    val newMessages = listOf(ChatMessage(Role.USER, "new conversation"), ChatMessage(Role.ASSISTANT, "retained new answer"))
    lateChat.restore(newMessages)
    nativeRelease.countDown(); lateWorker.join(2000); check(!lateWorker.isAlive && nativeCalls == 1)
    check(lateChat.messages == newMessages && !lateChat.isGenerating && lateChat.generationPhase == GenerationPhase.IDLE && !lateChat.lastHitTokenCap)
    check(lateFrames.filter { lateChat.isRevisionCurrent(it.first) }.all { it.second == newMessages })
    check(latePhases.filter { lateChat.isRevisionCurrent(it.first) }.all { it.second == GenerationPhase.IDLE })
    println("PASS: actual lifecycle-aware ChatModel admission, index-write/New Chat latch, stale native callbacks and queued UI events")
}

fun main(args: Array<String>) {
    require(args.size == 2) { "Expected shared fixture JSON and an owned scratch directory" }
    val root = File(args[1]); check(root.isDirectory)
    verifyPerformanceStorage(root)
    verifyAutomaticModeAndOwnership()
    verifyAppSelectionFlow(root)
    verifyLifecycleTurnAdmission()
    check(InferencePerformanceIdentity.artifact(ModelCatalog.entry("llama32-1b")!!.copy(sha256 = null)) == null)
    val split = ModelCatalog.models.first { it.artifacts.size > 1 }
    val identity = InferencePerformanceIdentity.artifact(split)!!
    check(InferencePerformanceIdentity.isSHA256(identity))
    check(InferencePerformanceIdentity.artifact(split.copy(artifacts = split.artifacts.reversed())) == null)
    val changedPart = split.artifacts.first().copy(sha256 = "f".repeat(64))
    check(InferencePerformanceIdentity.artifact(split.copy(artifacts = listOf(changedPart) + split.artifacts.drop(1))) != identity)
    check(InferencePerformanceIdentity.isSHA256(InferencePerformanceRuntime.ID))
    check(!LlamaEngine.NATIVE_AVAILABLE && !LlamaEngine.supportsPerformance && LlamaEngine.registeredRuntimeID == null)
    verifySharedPerformanceFixtures(File(args[0]))
    println("PASS: measured Automatic Kotlin policy, persistence and switch ownership")
}
