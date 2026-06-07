package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * JUnit/kotlin.test version for the Gradle build (`./gradlew test`). The same
 * invariants are also checked by the dependency-free `src/verify/CoreVerify.kt`
 * harness, which runs with just kotlinc + java.
 */
class CoreTest {

    @Test fun recommendationMatchesOtherPlatforms() {
        assertEquals("llama32-1b-q2", ModelRecommender.recommendedModelId(0.5))
        assertEquals("llama32-1b", ModelRecommender.recommendedModelId(2.99))
        assertEquals("llama32-3b", ModelRecommender.recommendedModelId(3.0))
        assertEquals("qwen3-4b", ModelRecommender.recommendedModelId(8.0))
        assertEquals("qwen3-14b", ModelRecommender.recommendedModelId(18.0))
    }

    @Test fun everyRecommendationResolves() {
        listOf(0.5, 2.0, 3.5, 8.0, 18.0, 64.0).forEach {
            assertNotNull(ModelCatalog.entry(ModelRecommender.recommendedModelId(it)))
        }
    }

    @Test fun catalogIntegrity() {
        assertEquals(11, ModelCatalog.models.size)
        assertEquals("llama32-1b-q2", ModelCatalog.smallest.id)
        ModelCatalog.models.forEach { assertNotNull(Quantization.info(it.quantization)) }
    }

    @Test fun memoryFitness() {
        assertFalse(MemoryFitness.check(ModelCatalog.entry("llama3-8b")!!, 8.0, 4.0).canLoad)
        assertEquals(MemorySeverity.SAFE, MemoryFitness.check(ModelCatalog.entry("llama32-1b")!!, 16.0, 12.0).severity)
    }

    @Test fun safetyBlocklist() {
        assertTrue(SafetyBlocklist.isBlocked("Tap Pay to complete"))
        assertTrue(SafetyBlocklist.matches("delete the file then pay").containsAll(listOf("delete", "pay")))
        assertFalse(SafetyBlocklist.isBlocked("Open the weather app"))
    }

    @Test fun mockEngine() {
        val engine = MockInferenceEngine("hi there friend")
        engine.load(ModelCatalog.smallest, "/dev/null")
        assertEquals("llama32-1b-q2", engine.loadedModelId)
        assertEquals("hi there friend", engine.complete("hello"))
        engine.unload()
        assertEquals(null, engine.loadedModelId)
    }

    @Test fun llamaEngineFailsCleanlyOffDevice() {
        val llama = LlamaEngine()
        assertFalse(llama.available(), "no native lib on the JVM")
        val e = runCatching { llama.load(ModelCatalog.smallest, "/dev/null") }.exceptionOrNull()
        assertNotNull(e)
        assertTrue(e!!.message!!.contains("not linked"))
        assertTrue(runCatching { llama.complete("hi") }.isFailure)
    }

    @Test fun onboardingReachesReady() {
        val phases = mutableListOf<OnboardingPhase>()
        val onboarding = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
            .apply { onChange = { phases += it } }
        onboarding.start { DeviceProfile(totalRamGB = 8.0, freeRamGB = 6.0) }
        assertEquals("qwen3-4b", (onboarding.phase as OnboardingPhase.Recommended).model.id)
        onboarding.acceptAndPrepare(ModelRecommender.recommendedModel(8.0))
        assertTrue(onboarding.phase is OnboardingPhase.Ready)
        assertTrue(phases.any { it is OnboardingPhase.Downloading })
    }

    @Test fun onboardingFailsWhenItCannotFit() {
        val onboarding = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        onboarding.start { DeviceProfile(totalRamGB = 2.0, freeRamGB = 0.2) }
        assertTrue(onboarding.phase is OnboardingPhase.Failed)
    }

    @Test fun chatAccumulatesTranscript() {
        val engine = MockInferenceEngine("Running on-device.")
        engine.load(ModelCatalog.smallest, "/dev/null")
        val sizes = mutableListOf<Int>()
        val chat = ChatModel(engine).apply { onChange = { sizes += it.size } }
        assertEquals("Running on-device.", chat.send("hello"))
        assertEquals(listOf(Role.USER, Role.ASSISTANT), chat.messages.map { it.role })
        assertEquals(listOf(1, 2), sizes)
        assertTrue(runCatching { chat.send("   ") }.isFailure)
    }
}
