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

    println()
    if (failures == 0) {
        println("ALL PASSED")
    } else {
        println("$failures CHECK(S) FAILED")
        kotlin.system.exitProcess(1)
    }
}
