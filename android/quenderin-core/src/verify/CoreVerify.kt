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

    // --- Model download engine (the resumable, pure-Kotlin brain of the WorkManager downloader) ---
    val payload = ByteArray(100) { (it % 7).toByte() }
    val sampleModel = ModelCatalog.smallest
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

    println()
    if (failures == 0) {
        println("ALL PASSED")
    } else {
        println("$failures CHECK(S) FAILED")
        kotlin.system.exitProcess(1)
    }
}
