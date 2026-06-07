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
}
