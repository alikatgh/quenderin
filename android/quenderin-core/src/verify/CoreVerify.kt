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

    println()
    if (failures == 0) {
        println("ALL PASSED")
    } else {
        println("$failures CHECK(S) FAILED")
        kotlin.system.exitProcess(1)
    }
}
