package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BonsaiRuntimeTest {
    private val bonsai get() = ModelCatalog.entry("bonsai2-27b")!!
    private fun device(budget: Double) = AndroidDeviceProfile("Test", AndroidSoc.SNAPDRAGON_8_ELITE,
        16.0, budget, 64.0, 4500.0)

    @Test fun pinnedArtifactAndQuantization() {
        assertEquals("Ternary-Bonsai-2-27B-PTQ1_0.gguf", bonsai.filename)
        assertEquals(27.36, bonsai.paramsBillions)
        assertEquals("53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3", bonsai.sha256)
        assertTrue(bonsai.url.contains("/b072e1d3b35a0a630cece372c2127528e0994386/"))
        assertEquals(1.75, Quantization.info("PTQ1_0")!!.bitsPerWeight)
        assertEquals(2.13, Quantization.info("PQ2_0")!!.bitsPerWeight)
        assertEquals(5_946_648_928L, DiskSpace.estimatedDownloadBytes(bonsai))
        assertEquals(5.946648928, AndroidModelSelector.estimatedDownloadGb(bonsai), 1e-9)
        assertEquals("llama32-1b-q2", ModelCatalog.smallest.id)
        assertFalse(AndroidModelSelector.defaultPreferenceIds.contains(bonsai.id))
    }

    @Test fun nativeCapabilityAndMemoryRemainIndependent() {
        assertFalse(ModelRuntimeSupport.supportsBonsai, "No native library exists in JVM tests")
        assertFalse(MemoryFitness.check(bonsai, 64.0, 64.0, prismRuntimeAvailable = false).canLoad)
        assertFalse(MemoryFitness.check(bonsai, 8.0, 8.0, prismRuntimeAvailable = true).canLoad)
        assertTrue(MemoryFitness.check(bonsai, 16.0, 16.0, prismRuntimeAvailable = true).canLoad)
        val low = AndroidModelSelector.fitness(bonsai, device(7.0), prismRuntimeAvailable = true)
        assertFalse(low.canLoad, "5.95 GB file does not establish RAM fitness")
        assertEquals(9.1, low.requiredGB, 1e-9)
        assertTrue(AndroidModelSelector.fitness(bonsai, device(12.0), prismRuntimeAvailable = true).canLoad)
        assertFalse(AndroidModelSelector.fitness(bonsai, device(20.0), prismRuntimeAvailable = false).canLoad)
    }

    @Test fun sideloadedIdentityOrCustomQuantizationRequiresPrism() {
        assertTrue(ModelRuntimeSupport.requiresPrism(bonsai.copy(id = "hf:copy", filename = "custom.gguf", quantization = "Q4_K_M")))
        val unknown = bonsai.copy(id = "custom", label = "Custom", filename = "custom.gguf",
            url = "https://example.com/custom.gguf", quantization = "pq2_0")
        assertTrue(ModelRuntimeSupport.requiresPrism(unknown))
        assertFalse(MemoryFitness.check(unknown, 64.0, 64.0, prismRuntimeAvailable = false).canLoad)
    }

    @Test fun stockEngineAndOnboardingRejectBeforeIOOrUnload() {
        val error = runCatching { LlamaEngine(64.0).load(bonsai, "/missing-bonsai-test.gguf") }.exceptionOrNull()
        assertEquals(ModelRuntimeSupport.UNAVAILABLE_MESSAGE, error?.message)
        val engine = MockInferenceEngine()
        engine.load(ModelCatalog.smallest, "/unused")
        var touchedDownloader = false
        val downloader = object : ModelDownloader {
            override fun needsFetch(model: ModelEntry): Boolean { touchedDownloader = true; error("unexpected file IO") }
            override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String { touchedDownloader = true; error("unexpected network") }
        }
        val onboarding = OnboardingModel(engine, downloader)
        onboarding.acceptAndPrepare(bonsai)
        assertEquals(ModelRuntimeSupport.UNAVAILABLE_MESSAGE, (onboarding.phase as OnboardingPhase.Failed).reason)
        assertFalse(touchedDownloader)
        assertEquals(ModelCatalog.smallest.id, engine.loadedModelId)
    }

    @Test fun stockDownloadEngineRejectsBeforeStorageOrNetwork() {
        val http = object : HttpRangeClient {
            override fun open(url: String, offsetBytes: Long): RangeResponse = error("unexpected network")
        }
        val sink = object : FileSink {
            override fun existingSize(path: String): Long = error("unexpected file IO")
            override fun truncate(path: String): Unit = error("unexpected file IO")
            override fun append(path: String, bytes: ByteArray): Unit = error("unexpected file IO")
            override fun head(path: String, n: Int): ByteArray = error("unexpected file IO")
            override fun sha256(path: String): String = error("unexpected file IO")
            override fun finalize(tempPath: String, finalPath: String): Unit = error("unexpected file IO")
        }
        val engine = ModelDownloadEngine(http, sink, DownloadStore(), "/unused")
        val error = runCatching { engine.download(bonsai) {} }.exceptionOrNull()
        assertEquals(ModelRuntimeSupport.UNAVAILABLE_MESSAGE, error?.message)
    }
}
