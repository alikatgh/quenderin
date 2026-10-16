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

    @Test fun smallerPinnedArtifactsKeepIndependentRuntimeAndMemoryGates() {
        data class Expected(val id: String, val bytes: Long, val revision: String, val sha: String, val required: Double)
        val expected = listOf(
            Expected("bonsai2-2b", 429_183_456L, "683f7be2629342a50987627b40881e54761a2430", "36061ad406df8a4903a6db005be350c50fabfaf717f9ef0acf4b76adcd9929fa", 1.95),
            Expected("bonsai2-4b", 949_549_920L, "8d6557168168f91ea6697a4a49ed2ef622b53adb", "56711263ec9a9ffeaa74a3a0e58dece8127cf9268404746c721113ca76994d60", 3.25),
            Expected("bonsai2-9b", 1_997_486_976L, "5b2abb02362efbed46bbe204014b02837778b2c2", "3561df7ac7d26a71ffa991ac2db740b10841c3a350aa2676ccd3ff5d428b4e8b", 5.2),
        )
        for (item in expected) {
            val model = ModelCatalog.entry(item.id)!!
            assertEquals(item.sha, model.sha256)
            assertEquals(item.bytes, model.downloadBytes)
            assertEquals(item.bytes, DiskSpace.estimatedDownloadBytes(model))
            assertTrue(model.url.contains("/resolve/${item.revision}/${model.filename}?download=true"))
            assertTrue(model.label.contains("(Experimental)"))
            assertTrue(ModelRuntimeSupport.requiresPrism(model))
            assertFalse(AndroidModelSelector.defaultPreferenceIds.contains(model.id))
            assertFalse(MemoryFitness.check(model, 64.0, 64.0, prismRuntimeAvailable = false).canLoad)
            assertEquals(item.required, MemoryFitness.check(model, 64.0, 64.0, prismRuntimeAvailable = true).requiredGB, 1e-9)
            assertFalse(AndroidModelSelector.fitness(model, device(item.required), prismRuntimeAvailable = true).canLoad)
            assertTrue(AndroidModelSelector.fitness(model, device(item.required * 2), prismRuntimeAvailable = true).canLoad)
        }
        assertEquals(4096, ModelRuntimeSupport.BONSAI_MAX_CONTEXT_TOKENS)
        for (ram in listOf(1.0, 2.0, 4.0, 8.0, 16.0, 64.0)) {
            assertFalse(ModelRecommender.recommendedModelId(ram).contains("bonsai"))
            assertFalse(ModelRecommender.bestInstallableModel(ram).id.contains("bonsai"))
        }
    }

    @Test fun smallerFloorsRequirePinnedIntegrityAndCannotUnderstateCatalogRam() {
        val pinned = ModelCatalog.entry("bonsai2-2b")!!
        val understated = pinned.copy(ramGB = 0.1)
        assertEquals(1.5, ModelRuntimeSupport.memoryFootprintGb(understated), 1e-9)
        for (imported in listOf(
            understated.copy(sha256 = null), understated.copy(downloadBytes = 1L),
            understated.copy(url = "https://example.com/custom.gguf"), understated.copy(paramsBillions = 27.0),
        )) {
            assertEquals(7.0, ModelRuntimeSupport.memoryFootprintGb(imported), 1e-9)
            assertEquals(9.1, MemoryFitness.check(imported, 64.0, 64.0, prismRuntimeAvailable = true).requiredGB, 1e-9)
        }
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
