package ai.quenderin.core

/**
 * Headless verification harness for the pure-Kotlin core — runnable with just
 * kotlinc + java (no Gradle/Android needed). The Android Studio module adds
 * proper JUnit/kotlin.test versions; this proves the logic matches the Swift and
 * desktop implementations.
 *
 *   kotlinc  (the core .kt files)  src/verify/CoreVerify.kt \
 *       -include-runtime -d core.jar  &&  java -jar core.jar
 */

private var failures = 0

private fun check(name: String, cond: Boolean) {
    if (cond) {
        println("  ok   $name")
    } else {
        println("  FAIL $name")
        failures++
    }
}

/** In-memory [FileSink] for the download-engine checks — no real disk. */
private class FakeFileSink : FileSink {
    val files = HashMap<String, ByteArray>()
    override fun existingSize(path: String): Long = files[path]?.size?.toLong() ?: 0L
    override fun truncate(path: String) { files.remove(path) }
    override fun append(path: String, bytes: ByteArray) {
        files[path] = (files[path] ?: ByteArray(0)) + bytes
    }
    override fun head(path: String, n: Int): ByteArray {
        val b = files[path] ?: ByteArray(0)
        return b.copyOf(minOf(n, b.size))
    }
    override fun sha256(path: String): String =
        ModelIntegrity.sha256Hex(files[path] ?: throw java.io.FileNotFoundException(path))
    override fun finalize(tempPath: String, finalPath: String) {
        files[finalPath] = files.remove(tempPath) ?: ByteArray(0)
    }
}

/** In-memory range-aware [HttpRangeClient] for the download-engine checks. */
private class FakeHttpRangeClient(
    private val full: ByteArray,
    private val supportsResume: Boolean,
    private val chunk: Int = 8,
) : HttpRangeClient {
    var lastOffset: Long = -1
    override fun open(url: String, offsetBytes: Long): RangeResponse {
        lastOffset = offsetBytes
        val start = if (supportsResume) offsetBytes.toInt().coerceIn(0, full.size) else 0
        val slice = full.copyOfRange(start, full.size)
        val body = slice.toList().chunked(chunk).map { it.toByteArray() }.asSequence()
        return RangeResponse(totalBytes = full.size.toLong(), resumed = supportsResume && offsetBytes > 0, body = body)
    }
}

fun main() {
    println("QuenderinCore (Android / Kotlin) verification\n")

    // --- Recommendation bands (must match Swift ModelRecommender + desktop TS) ---
    check("ultra-light below 1.5 GB", ModelRecommender.recommendedModelId(0.5) == "llama32-1b-q2")
    check("1B from 1.5 to <3 GB", ModelRecommender.recommendedModelId(2.99) == "llama32-1b")
    check("3B from 3 to <4 GB", ModelRecommender.recommendedModelId(3.0) == "llama32-3b")
    check("Qwen3 4B from 4 to <10 GB", ModelRecommender.recommendedModelId(8.0) == "qwen3-4b")
    check("Qwen3 14B at 10+ GB", ModelRecommender.recommendedModelId(18.0) == "qwen3-14b")
    check("every recommended id resolves to a catalog entry",
        listOf(0.5, 2.0, 3.5, 8.0, 18.0, 64.0).all { ModelCatalog.entry(ModelRecommender.recommendedModelId(it)) != null })

    // --- Catalog integrity ---
    check("11 models across families", ModelCatalog.models.size == 11)
    check("smallest is the ultra-light", ModelCatalog.smallest.id == "llama32-1b-q2")
    check("every model uses a known quant", ModelCatalog.models.all { Quantization.info(it.quantization) != null })
    check("catalog spans 6 families", listOf("qwen3-14b", "deepseek-r1-7b", "gemma3-4b", "phi4-mini", "mistral-7b", "llama3-8b").all { ModelCatalog.entry(it) != null })

    // --- Memory fitness ---
    check("8B blocked on an 8 GB device with 4 GB free",
        !MemoryFitness.check(ModelCatalog.entry("llama3-8b")!!, totalGB = 8.0, freeGB = 4.0).canLoad)
    check("1B safe on a 16 GB device",
        MemoryFitness.check(ModelCatalog.entry("llama32-1b")!!, totalGB = 16.0, freeGB = 12.0).severity == MemorySeverity.SAFE)

    // --- Safety blocklist ---
    check("blocks a Pay action", SafetyBlocklist.isBlocked("Tap Pay to complete"))
    check("blocks Delete + Password", SafetyBlocklist.matches("Delete the file and type the password").containsAll(listOf("delete", "password")))
    check("allows a safe action", !SafetyBlocklist.isBlocked("Open the weather app"))

    // --- Inference seam (mock) ---
    val engine = MockInferenceEngine(cannedReply = "one two three")
    engine.load(ModelCatalog.smallest, "/dev/null")
    check("mock engine reports the loaded model", engine.loadedModelId == "llama32-1b-q2")
    check("mock engine completes a prompt", engine.complete("hi") == "one two three")
    engine.unload()
    check("unload clears the loaded model", engine.loadedModelId == null)

    // --- LlamaEngine: fails cleanly off-device (no .so), per the JNI contract ---
    val llama = LlamaEngine()
    check("LlamaEngine reports unavailable on the JVM (no native lib)", !llama.available())
    check("LlamaEngine.load throws a clear 'not linked' error when unlinked",
        runCatching { llama.load(ModelCatalog.smallest, "/dev/null") }
            .exceptionOrNull()?.message?.contains("not linked") == true)
    check("LlamaEngine.complete throws when unlinked", runCatching { llama.complete("hi") }.isFailure)

    // --- OnboardingModel (M1): probe → recommend → download(mock) → load(mock) → ready ---
    val phases = mutableListOf<OnboardingPhase>()
    val onboarding = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        .apply { onChange = { phases += it } }
    onboarding.start { DeviceProfile(totalRamGB = 8.0, freeRamGB = 6.0) }
    check("onboarding recommends Qwen3 4B for an 8 GB device",
        (onboarding.phase as? OnboardingPhase.Recommended)?.model?.id == "qwen3-4b")
    onboarding.acceptAndPrepare(ModelRecommender.recommendedModel(8.0))
    check("onboarding reaches Ready", onboarding.phase is OnboardingPhase.Ready)
    check("onboarding streamed Downloading progress", phases.any { it is OnboardingPhase.Downloading })
    check("onboarding fails cleanly when even the recommended model can't fit", run {
        val tight = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        tight.start { DeviceProfile(totalRamGB = 2.0, freeRamGB = 0.2) }
        tight.phase is OnboardingPhase.Failed
    })

    // --- ChatModel (M2): send runs the engine, transcript accumulates ---
    val chatEngine = MockInferenceEngine(cannedReply = "Running on-device.")
    chatEngine.load(ModelCatalog.smallest, "/dev/null")
    val sizes = mutableListOf<Int>()
    val chat = ChatModel(chatEngine).apply { onChange = { sizes += it.size } }
    val reply = chat.send("hello")
    check("chat returns the engine reply", reply == "Running on-device.")
    check("chat transcript is user then assistant",
        chat.messages.map { it.role } == listOf(Role.USER, Role.ASSISTANT))
    check("chat emitted after each append", sizes == listOf(1, 2))
    check("chat rejects an empty message", runCatching { chat.send("   ") }.isFailure)

    // --- ConversationContext (chat memory + context-window budgeting; twin of Swift) ---
    check("conversation context keeps multi-turn history (no amnesia)", run {
        val p = ConversationContext().build(
            listOf(
                ChatMessage(Role.USER, "remember apples"),
                ChatMessage(Role.ASSISTANT, "ok"),
                ChatMessage(Role.USER, "what did I say?"),
            )
        )
        p.contains("remember apples") && p.contains("ok") && p.contains("what did I say?")
    })
    check("conversation context leads with the system prompt + ends primed for the assistant", run {
        val p = ConversationContext().build(listOf(ChatMessage(Role.USER, "hi")))
        p.contains("Quenderin") && p.trimEnd().endsWith("Assistant:")
    })
    check("conversation context drops oldest turns past the token budget, keeps newest", run {
        val ctx = ConversationContext(systemPrompt = "", contextTokens = 80, reservedForResponse = 0)
        val history = (1..20).map {
            ChatMessage(if (it % 2 == 1) Role.USER else Role.ASSISTANT, "message number $it here")
        }
        val p = ctx.build(history)
        !p.contains("message number 1 here") && p.contains("message number 20 here")
    })
    check("conversation context never drops the latest turn even if it alone exceeds budget", run {
        val ctx = ConversationContext(systemPrompt = "", contextTokens = 4, reservedForResponse = 0)
        ctx.build(listOf(ChatMessage(Role.USER, "a single message far larger than the tiny budget")))
            .contains("a single message far larger")
    })
    check("ChatModel feeds prior history back to the engine (memory, not amnesia)", run {
        val captured = mutableListOf<String>()
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "cap"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String { captured += prompt; return "ok" }
        }
        val chat = ChatModel(engine)
        chat.send("remember apples")
        chat.send("recall?")
        captured.last().contains("remember apples") && captured.last().contains("ok")
    })

    // --- ConversationStore (offline persistence: a transcript survives relaunch; twin of Swift) ---
    check("conversation store round-trips roles, text, and order", run {
        val store = ConversationStore()
        val original = listOf(
            ChatMessage(Role.USER, "hi"),
            ChatMessage(Role.ASSISTANT, "hello there"),
            ChatMessage(Role.USER, "bye"),
        )
        val restored = store.decode(store.encode(original))
        restored.map { it.role } == original.map { it.role } && restored.map { it.text } == original.map { it.text }
    })
    check("conversation store decodes blank input to an empty conversation", run {
        ConversationStore().decode("").isEmpty() && ConversationStore().decode("   ").isEmpty()
    })
    check("conversation store survives newlines, tabs, and backslashes in message text", run {
        val store = ConversationStore()
        val tricky = listOf(
            ChatMessage(Role.USER, "line one\nline two\twith tab"),
            ChatMessage(Role.ASSISTANT, "back\\slash and \"quotes\""),
        )
        store.decode(store.encode(tricky)).map { it.text } == tricky.map { it.text }
    })
    check("ChatModel.restore seeds a saved transcript", run {
        val chat = ChatModel(MockInferenceEngine())
        chat.restore(listOf(ChatMessage(Role.USER, "earlier question"), ChatMessage(Role.ASSISTANT, "earlier answer")))
        chat.messages.size == 2 && chat.messages.first().text == "earlier question"
    })

    // --- ConversationLibrary (chat-history index: recency list / upsert / remove / title; twin of Swift) ---
    check("conversation library lists most-recent-first with a stable id tie-break", run {
        val lib = ConversationLibrary()
        lib.upsert(ConversationSummary("a", "A", 100))
        lib.upsert(ConversationSummary("c", "C", 300))
        lib.upsert(ConversationSummary("b", "B", 300))
        lib.list().map { it.id } == listOf("b", "c", "a")
    })
    check("conversation library upsert replaces by id", run {
        val lib = ConversationLibrary()
        lib.upsert(ConversationSummary("a", "first", 100))
        lib.upsert(ConversationSummary("a", "renamed", 200))
        lib.count == 1 && lib.get("a")?.title == "renamed" && lib.get("a")?.updatedAt == 200L
    })
    check("conversation library remove + snapshot/restore round-trip", run {
        val lib = ConversationLibrary()
        lib.upsert(ConversationSummary("a", "A", 1))
        lib.upsert(ConversationSummary("b", "B", 2))
        lib.remove("a") && ConversationLibrary(lib.snapshot()).list().map { it.id } == listOf("b")
    })
    check("conversation library derives a title from the first user message", run {
        ConversationLibrary.titleFromFirstUserMessage(null) == "New conversation" &&
            ConversationLibrary.titleFromFirstUserMessage("  hello   there  ") == "hello there" &&
            ConversationLibrary.titleFromFirstUserMessage("x".repeat(60)).let { it.length == 41 && it.endsWith("…") }
    })

    // --- ConversationManager (capstone: lifecycle over library + persistence; twin of Swift) ---
    check("conversation manager startNew creates a titled, current, listed conversation", run {
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { 1000L }, makeId = { "c1" })
        val id = mgr.startNew()
        mgr.currentId == id && mgr.list().size == 1 && mgr.list().first().title == "New conversation"
    })
    check("conversation manager save derives a title and persists the transcript", run {
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { 1000L }, makeId = { "c1" })
        val id = mgr.startNew()
        mgr.save(id, listOf(ChatMessage(Role.USER, "How do I center a div?"), ChatMessage(Role.ASSISTANT, "Flexbox.")))
        mgr.list().first().title == "How do I center a div?" && mgr.open(id).size == 2
    })
    check("conversation manager lists newest-first and a touch re-sorts to top", run {
        var clock = 1000L
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { clock }, makeId = { "id-$clock" })
        val first = mgr.startNew(); clock += 1000
        val second = mgr.startNew()
        val newestIsSecond = mgr.list().first().id == second
        clock += 1000
        mgr.save(first, listOf(ChatMessage(Role.USER, "hi")))
        newestIsSecond && mgr.list().first().id == first
    })
    check("conversation manager delete removes everywhere and clears current", run {
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { 1L }, makeId = { "c1" })
        val id = mgr.startNew()
        mgr.save(id, listOf(ChatMessage(Role.USER, "hi")))
        mgr.delete(id)
        mgr.list().isEmpty() && mgr.currentId == null && mgr.open(id).isEmpty()
    })
    check("conversation manager history survives a fresh instance (persistence-backed)", run {
        val p = InMemoryConversationPersistence()
        val id = ConversationManager(p, now = { 5L }, makeId = { "c1" }).let { m -> m.startNew().also { m.save(it, listOf(ChatMessage(Role.USER, "remembered question"))) } }
        val reopened = ConversationManager(p, now = { 9L }, makeId = { "x" })
        reopened.list().map { it.id } == listOf(id) && reopened.open(id).size == 1 &&
            reopened.list().first().title == "remembered question"
    })

    // --- ModelManager (multi-model lifecycle: installed / active / usage / delete; twin of Swift) ---
    run {
        val small = ModelCatalog.smallest
        val mid = ModelCatalog.entry("qwen3-4b")!!
        fun storage() = InMemoryModelStorage().apply { install(small.filename, 300); install(mid.filename, 4000) }

        check("model manager lists only on-disk catalog models with sizes + total usage", run {
            val mgr = ModelManager(storage())
            mgr.installed().map { it.id }.toSet() == setOf(small.id, mid.id) && mgr.totalBytesUsed == 4300L
        })
        check("model manager pins the active model to the top and rejects activating an uninstalled one", run {
            val mgr = ModelManager(storage())
            mgr.setActive(small.id) && mgr.installed().first().id == small.id && !mgr.setActive("nope")
        })
        check("model manager delete reclaims bytes and clears active when the active model is removed", run {
            val mgr = ModelManager(storage(), initialActiveModelId = mid.id)
            val reclaimableOk = mgr.reclaimableBytes == 300L
            val freed = mgr.delete(mid.id)
            reclaimableOk && freed == 4000L && mgr.activeModelId == null && !mgr.isInstalled(mid.id) && mgr.totalBytesUsed == 300L
        })
        check("model manager delete of an uninstalled model is a no-op", run {
            val mgr = ModelManager(InMemoryModelStorage().apply { install(small.filename, 300) })
            mgr.delete("qwen3-14b") == 0L && mgr.totalBytesUsed == 300L
        })
    }

    // --- Android SoC resolution + native-heap memory model ---
    check("resolves Snapdragon 8 Gen 3", AndroidSoc.fromSocModel("SM8650") == AndroidSoc.SNAPDRAGON_8_GEN_3)
    check("resolves Dimensity 9300", AndroidSoc.fromSocModel("MT6989") == AndroidSoc.DIMENSITY_9300)
    check("unknown SoC falls back", AndroidSoc.fromSocModel("mystery-chip") == AndroidSoc.UNKNOWN)
    check("native budget below total RAM but generous", run {
        val b = AndroidSoc.nativeMemoryBudgetGB(8.0); b < 8.0 && b > 5.0
    })
    check("Android handles 16 GB tiers no iPhone has", AndroidSoc.nativeMemoryBudgetGB(16.0) >= 11.0)

    // --- Android model selector: device-aware, jetsam-free picks ---
    fun androidProfile(name: String, soc: AndroidSoc, ram: Double) =
        AndroidDeviceProfile(name, soc, ram, AndroidSoc.nativeMemoryBudgetGB(ram), freeDiskGb = 128.0, batteryMAh = 4500.0)

    check("4 GB mid-range Android → 1B",
        AndroidModelSelector.select(androidProfile("Budget", AndroidSoc.MIDRANGE, 4.0)).model.id == "llama32-1b")
    check("6 GB Snapdragon 8 Gen 2 → 4B",
        AndroidModelSelector.select(androidProfile("Mid", AndroidSoc.SNAPDRAGON_8_GEN_2, 6.0)).model.id == "qwen3-4b")
    check("8 GB Snapdragon 8 Gen 3 → 4B, 7B offered", run {
        val sel = AndroidModelSelector.select(androidProfile("Flagship", AndroidSoc.SNAPDRAGON_8_GEN_3, 8.0))
        sel.model.id == "qwen3-4b" && sel.alternatives.any { it.model.id == "mistral-7b" }
    })
    check("16 GB Snapdragon 8 Elite → 7B (RAM no iPhone has unlocks it)",
        AndroidModelSelector.select(androidProfile("Gaming", AndroidSoc.SNAPDRAGON_8_ELITE, 16.0)).model.id == "mistral-7b")
    check("same 12 GB, faster chip picks bigger", run {
        val elite = AndroidModelSelector.select(androidProfile("A", AndroidSoc.SNAPDRAGON_8_ELITE, 12.0)).model.id
        val gen1 = AndroidModelSelector.select(androidProfile("B", AndroidSoc.SNAPDRAGON_8_GEN_1, 12.0)).model.id
        elite == "mistral-7b" && gen1 == "qwen3-4b"
    })
    check("14B never auto-picked on a phone (too slow even at 16 GB)",
        AndroidModelSelector.select(androidProfile("Gaming", AndroidSoc.SNAPDRAGON_8_ELITE, 16.0)).model.id != "qwen3-14b")
    check("Android pick carries a thermal/battery estimate", run {
        val tb = AndroidModelSelector.select(androidProfile("Flagship", AndroidSoc.SNAPDRAGON_8_GEN_3, 8.0)).thermalBattery
        tb.mAhPer1KTokens > 0 && tb.sustainedVerdict.contains("%/hr")
    })
    check("onboarding via AndroidDeviceProfile uses the selector", run {
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        onb.start(AndroidDeviceProfile.from("Flagship", "SM8650", totalRamGb = 8.0, freeDiskGb = 128.0))
        val ph = onb.phase
        ph is OnboardingPhase.Recommended && ph.model.id == "qwen3-4b" && onb.selection != null
    })

    // --- M3 offline-readiness (Android parity with iOS) ---
    check("Wi-Fi-only policy blocks cellular", !DownloadPolicy.WIFI_ONLY.allows(NetworkStatus.CELLULAR))
    check("Wi-Fi-only policy allows Wi-Fi", DownloadPolicy.WIFI_ONLY.allows(NetworkStatus.WIFI))
    check("no connection is always blocked", !DownloadPolicy.WIFI_OR_CELLULAR.allows(NetworkStatus.NONE))
    check("a held-back download explains why", DownloadPolicy.WIFI_ONLY.reason(NetworkStatus.CELLULAR)?.contains("Wi-Fi") == true)
    check("disk check blocks a 4B on a near-full device",
        !DiskSpace.check(ModelCatalog.entry("qwen3-4b")!!, availableBytes = 100L * 1024 * 1024).hasRoom)
    check("disk check passes with ample room",
        DiskSpace.check(ModelCatalog.smallest, availableBytes = 50L * 1024 * 1024 * 1024).hasRoom)
    check("a missing model is not offline-ready",
        !OfflineReadinessChecker.evaluate(ModelCatalog.smallest, fileExists = false, fileSizeBytes = 0).isReadyForOffline)
    check("a complete file IS offline-ready", run {
        val m = ModelCatalog.smallest
        OfflineReadinessChecker.evaluate(m, fileExists = true, fileSizeBytes = DiskSpace.estimatedDownloadBytes(m)).isReadyForOffline
    })
    check("a half-downloaded file reports incomplete %", run {
        val m = ModelCatalog.smallest
        val r = OfflineReadinessChecker.evaluate(m, fileExists = true, fileSizeBytes = DiskSpace.estimatedDownloadBytes(m) / 2)
        !r.isReadyForOffline && r.message.contains("%")
    })

    // --- M4 agent loop (Android parity): plan → safety-gate → execute → observe → repeat ---
    check("arithmetic parser evaluates precedence + parens", ArithmeticParser.evaluate("12 * (3 + 4)") == 84.0)
    check("arithmetic parser rejects malformed input", ArithmeticParser.evaluate("2 +* 3") == null)
    check("arithmetic parser rejects divide-by-zero", ArithmeticParser.evaluate("4 / 0") == null)
    check("calculator renders integers cleanly", CalculatorTool().run("20 + 22") == "42")
    check("units converts length", UnitConverterTool().run("1 km to m") == "1 km = 1000 m")
    check("units handles affine temperature", UnitConverterTool().run("30 C to F") == "30 c = 86 f")
    check("units resolves spelled-out aliases", UnitConverterTool().run("5 kilometers to miles").contains("3.10"))
    check("units rejects cross-dimension", UnitConverterTool().run("5 kg to mi").contains("Can't convert"))
    check("units rejects garbage", UnitConverterTool().run("hello world").contains("Couldn't read"))
    check("date counts days between (order-independent)", DateCalcTool().run("days between 2026-12-25 and 2026-06-08") == "200 days")
    check("date adds days across months", DateCalcTool().run("2026-06-08 plus 90 days") == "2026-09-06")
    check("date subtracts days", DateCalcTool().run("2026-12-25 minus 14 days") == "2026-12-11")
    check("date rejects garbage", DateCalcTool().run("what time is it").contains("Couldn't read"))
    check("decision parser reads a tool call",
        AgentDecisionParser.parse("""{"tool":"calculator","input":"2+2"}""") == AgentDecision.UseTool("calculator", "2+2"))
    check("decision parser reads a final answer wrapped in prose",
        AgentDecisionParser.parse("""Sure thing! {"answer":"42"} hope that helps""") == AgentDecision.FinalAnswer("42"))
    check("agent loop uses a tool then answers", run {
        val engine = ScriptedInferenceEngine(listOf(
            """{"tool":"calculator","input":"20 + 22"}""",
            """{"answer":"The answer is 42."}""",
        ))
        val r = AgentLoop(engine, listOf(CalculatorTool())).run("What is 20 + 22?")
        r.haltReason == AgentRun.HaltReason.ANSWERED && r.answer == "The answer is 42." && r.steps.any { it.observation == "42" }
    })
    check("agent loop safety-gates a blocked action", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"echo","input":"delete my files and pay"}"""))
        AgentLoop(engine, listOf(EchoTool())).run("do it").haltReason == AgentRun.HaltReason.BLOCKED
    })
    check("agent loop halts cleanly on a non-JSON plan",
        AgentLoop(ScriptedInferenceEngine(listOf("not json")), emptyList()).run("x").haltReason == AgentRun.HaltReason.PLAN_ERROR)
    check("agent loop caps runaway steps", run {
        val engine = ScriptedInferenceEngine(List(10) { """{"tool":"echo","input":"loop"}""" })
        AgentLoop(engine, listOf(EchoTool()), maxSteps = 3).run("x").haltReason == AgentRun.HaltReason.MAX_STEPS
    })
    check("agent loop streams steps live via onStep", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"calculator","input":"1+1"}""", """{"answer":"done"}"""))
        val streamed = mutableListOf<AgentStep>()
        val r = AgentLoop(engine, listOf(CalculatorTool())).run("x") { streamed.add(it) }
        streamed.size == r.steps.size && streamed.size == 2
    })
    check("agent session runs and publishes the result", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"calculator","input":"2+2"}""", """{"answer":"4"}"""))
        var changes = 0
        val session = AgentSession(engine, listOf(CalculatorTool())) { changes++ }
        session.run("2+2?")
        session.answer == "4" && session.steps.size == 2 && !session.isRunning &&
            session.haltReason == AgentRun.HaltReason.ANSWERED && changes > 0
    })

    // --- M3 resume bookkeeping (DownloadStore) ---
    check("download store tracks fraction complete", run {
        val store = DownloadStore()
        store.upsert(PersistedDownload("qwen3-4b", "q.gguf", "https://x", "/tmp/q.gguf", totalBytes = 1000))
        store.updateProgress("qwen3-4b", bytesDownloaded = 250, totalBytes = 1000)
        store.get("qwen3-4b")?.fractionComplete == 0.25
    })
    check("paused download resumes from its byte offset", run {
        val d = PersistedDownload("m", "f", "u", "/p", bytesDownloaded = 500, totalBytes = 1000, state = PersistedDownload.State.PAUSED)
        d.resumeOffset == 500L
    })
    check("completed download resumes from 0", run {
        PersistedDownload("m", "f", "u", "/p", 1000, 1000, PersistedDownload.State.COMPLETED).resumeOffset == 0L
    })
    check("download store restores from a snapshot", run {
        val store = DownloadStore()
        store.upsert(PersistedDownload("m", "f", "u", "/p", bytesDownloaded = 300, totalBytes = 900))
        DownloadStore(store.snapshot()).get("m")?.bytesDownloaded == 300L
    })
    check("resumable() returns only in-flight (running/paused) rows", run {
        val store = DownloadStore()
        store.upsert(PersistedDownload("a", "a", "u", "/p", state = PersistedDownload.State.RUNNING))
        store.upsert(PersistedDownload("b", "b", "u", "/p", state = PersistedDownload.State.PAUSED))
        store.upsert(PersistedDownload("c", "c", "u", "/p", state = PersistedDownload.State.COMPLETED))
        store.resumable().map { it.modelId }.toSet() == setOf("a", "b")
    })

    // --- Model integrity (GGUF magic + SHA-256 verification; audit C3) ---
    check("GGUF magic detected on a real header", ModelIntegrity.hasGGUFMagic(ModelIntegrity.GGUF_MAGIC + byteArrayOf(1, 2, 3)))
    check("non-GGUF bytes rejected", !ModelIntegrity.hasGGUFMagic("<htm".toByteArray()))
    check("too-short buffer is not GGUF", !ModelIntegrity.hasGGUFMagic(byteArrayOf(0x47, 0x47)))
    check("sha256 matches the NIST 'abc' test vector",
        ModelIntegrity.sha256Hex("abc".toByteArray()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    // --- Support contact (Generative-AI "report this response" mailto; twin of Swift) ---
    check("report mailto targets the support address", run {
        val uri = SupportContact.reportMailtoUri("hello", "chat")
        uri.startsWith("mailto:${SupportContact.REPORT_EMAIL}?") && uri.contains("subject=") && uri.contains("body=")
    })
    check("report mailto percent-encodes special chars so model output can't break the URI", run {
        val uri = SupportContact.reportMailtoUri("danger & death = bad?", "agent")
        !uri.contains("danger & death") && uri.contains("danger") && !uri.contains(" ")
    })
    check("AI disclaimer is non-empty", SupportContact.AI_DISCLAIMER.isNotEmpty())

    // --- Model download engine (the resumable, pure-Kotlin brain of the WorkManager downloader) ---
    // A 100-byte body starting with the GGUF magic + a catalog entry pinned to its hash, so the
    // engine's integrity gate (C3) passes on the happy paths below.
    val payload = ModelIntegrity.GGUF_MAGIC + ByteArray(96) { (it % 7).toByte() }
    val sampleModel = ModelCatalog.smallest.copy(sha256 = ModelIntegrity.sha256Hex(payload))
    val finalFile = "/models/${sampleModel.filename}"
    val partFile = "$finalFile.part"

    check("fresh download writes the full file, returns its path, finishes at 1.0, clears the store", run {
        val sink = FakeFileSink()
        val store = DownloadStore()
        val engine = ModelDownloadEngine(FakeHttpRangeClient(payload, supportsResume = true), sink, store, "/models")
        var last = 0.0
        val path = engine.download(sampleModel) { last = it }
        sink.files[finalFile]?.size == 100 && path == finalFile && last == 1.0 && store.get(sampleModel.id) == null
    })
    check("a half-written .part resumes from its byte offset to the correct full file", run {
        val sink = FakeFileSink().apply { files[partFile] = payload.copyOfRange(0, 40) }
        val http = FakeHttpRangeClient(payload, supportsResume = true)
        ModelDownloadEngine(http, sink, DownloadStore(), "/models").download(sampleModel) {}
        http.lastOffset == 40L && sink.files[finalFile]?.toList() == payload.toList()
    })
    check("a server that can't resume restarts cleanly to the correct full file", run {
        val sink = FakeFileSink().apply { files[partFile] = payload.copyOfRange(0, 40) }
        ModelDownloadEngine(FakeHttpRangeClient(payload, supportsResume = false), sink, DownloadStore(), "/models")
            .download(sampleModel) {}
        sink.files[finalFile]?.toList() == payload.toList()
    })
    check("a transport failure throws DownloadException and marks the row FAILED", run {
        val store = DownloadStore()
        val boom = object : HttpRangeClient {
            override fun open(url: String, offsetBytes: Long): RangeResponse = throw RuntimeException("network down")
        }
        val result = runCatching { ModelDownloadEngine(boom, FakeFileSink(), store, "/models").download(sampleModel) {} }
        result.exceptionOrNull() is DownloadException &&
            store.get(sampleModel.id)?.state == PersistedDownload.State.FAILED
    })
    check("integrity gate rejects a non-GGUF body and fails the download (C3)", run {
        val notGguf = ByteArray(100) { (it % 7).toByte() } // valid length, no GGUF magic
        val result = runCatching {
            ModelDownloadEngine(FakeHttpRangeClient(notGguf, supportsResume = true), FakeFileSink(), DownloadStore(), "/models")
                .download(ModelCatalog.smallest.copy(sha256 = null)) {}
        }
        result.exceptionOrNull().let { it is DownloadException && it.message?.contains("GGUF") == true }
    })
    check("integrity gate rejects a checksum mismatch and discards the partial (C3)", run {
        val sink = FakeFileSink()
        val result = runCatching {
            ModelDownloadEngine(FakeHttpRangeClient(payload, supportsResume = true), sink, DownloadStore(), "/models")
                .download(sampleModel.copy(sha256 = "f".repeat(64))) {}
        }
        result.exceptionOrNull() is DownloadException && sink.files[partFile] == null && sink.files[finalFile] == null
    })

    // ── Content-safety surface (Generative-AI store policy). Twin of iOS SupportContactTests. ──
    check("report mailto targets the support address", run {
        SupportContact.reportMailtoUri("hello", "chat").startsWith("mailto:${SupportContact.REPORT_EMAIL}?")
    })
    check("report mailto carries subject + body", run {
        val uri = SupportContact.reportMailtoUri("hello", "chat")
        uri.contains("subject=") && uri.contains("body=")
    })
    check("report mailto percent-encodes sub-delimiters so output can't break the URI", run {
        val uri = SupportContact.reportMailtoUri("danger & death = bad?", "agent")
        // raw '&', spaces, '=', '?' from the model text must be encoded, not left literal in the query.
        !uri.contains("danger & death") && uri.contains("danger") && uri.contains("death") &&
            // exactly one literal '&'/'=' /'?' — the ones we placed as query separators.
            uri.count { it == '&' } == 1 && uri.substringAfter("?subject=").count { it == '?' } == 0
    })
    check("report mailto uses %20 for spaces (mailto clients reject '+')", run {
        SupportContact.reportMailtoUri("a b c", "chat").contains("%20") &&
            !SupportContact.reportMailtoUri("a b c", "chat").substringAfter("body=").contains("+")
    })
    check("report mailto caps the snippet at ~1000 chars", run {
        val long = "x".repeat(5000)
        // encoded body stays bounded: 1000 'x' + ellipsis + boilerplate, not 5000.
        SupportContact.reportMailtoUri(long, "chat").count { it == 'x' } <= 1100
    })
    check("AI disclaimer is non-empty", SupportContact.AI_DISCLAIMER.isNotEmpty())

    println()
    if (failures == 0) {
        println("ALL PASSED")
    } else {
        println("$failures CHECK(S) FAILED")
        kotlin.system.exitProcess(1)
    }
}
