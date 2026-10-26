package ai.quenderin.core

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Engine-side ChatCapStatus contract. ChatModel wiring is deliberately out of scope; these tests
 * pin the engine/adapters' declared reasons, the no-circular default, the clean-measured mapping,
 * independent legacy booleans, automatic model transactions, and suspension/stale publication.
 */
class ChatCapStatusTest {

    private class CapFake(
        var status: ChatCapStatus = ChatCapStatus.UNKNOWN,
        private val pieces: List<String> = emptyList(),
    ) : InferenceEngine {
        var failLoad = false
        var legacyHit = false
        private var loaded: String? = "cap-fake"
        override val loadedModelId: String? get() = loaded
        override fun load(model: ModelEntry, filePath: String) {
            if (failLoad) error("fixture load failure")
            loaded = model.id
        }
        override fun unload() { loaded = null }
        override fun complete(prompt: String): String = pieces.joinToString("")
        override fun completeChat(
            systemPrompt: String,
            history: List<ChatMessage>,
            onToken: (String) -> Unit,
        ): String {
            pieces.forEach(onToken)
            return pieces.joinToString("")
        }
        override fun chatCapStatus(): ChatCapStatus = status
        override fun lastHitTokenCap(): Boolean = legacyHit
    }

    /** Blocks a completion after it was admitted, so a Stop/suspension can interleave. */
    private class LatchedEngine(private var status: ChatCapStatus = ChatCapStatus.HIT) : InferenceEngine {
        val entered = CountDownLatch(1)
        val cancelEntered = CountDownLatch(1)
        val release = CountDownLatch(1)
        private var loaded: String? = "latched"
        override val loadedModelId: String? get() = loaded
        override fun load(model: ModelEntry, filePath: String) { loaded = model.id }
        override fun unload() { loaded = null }
        override fun complete(prompt: String): String = ""
        override fun requestCancel() { cancelEntered.countDown() }
        override fun completeChat(
            systemPrompt: String,
            history: List<ChatMessage>,
            onToken: (String) -> Unit,
        ): String {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS)) { "fixture completion was not released" }
            return "done"
        }
        override fun chatCapStatus(): ChatCapStatus = status
    }

    /** Native completion is done; only the wrapper's status read remains suspended. */
    private class StatusLatchedEngine : InferenceEngine {
        val statusEntered = CountDownLatch(1)
        val releaseStatus = CountDownLatch(1)
        val cancelEntered = CountDownLatch(1)
        override val loadedModelId: String? = "status-latched"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = "done"
        override fun requestCancel() { cancelEntered.countDown() }
        override fun lastHitTokenCap(): Boolean = true
        override fun chatCapStatus(): ChatCapStatus {
            statusEntered.countDown()
            check(releaseStatus.await(5, TimeUnit.SECONDS)) { "fixture status was not released" }
            return ChatCapStatus.HIT
        }
    }

    private fun tinyModel(): Pair<ModelEntry, File> {
        val file = File.createTempFile("cap-tiny-", ".gguf")
        file.writeBytes("GGUF".toByteArray())
        val model = ModelCatalog.smallest.copy(
            id = "cap-tiny-${file.name}",
            filename = file.name,
            downloadBytes = file.length(),
            sha256 = ModelIntegrity.sha256Hex(file),
            artifacts = emptyList(),
        )
        return model to file
    }

    @Test fun defaultStatusIsUnknownAndDoesNotDeriveFromTheLegacyBoolean() {
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = null
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = ""
            override fun lastHitTokenCap(): Boolean = true
        }

        assertEquals(ChatCapStatus.UNKNOWN, engine.chatCapStatus())
        assertTrue(engine.lastHitTokenCap(), "the legacy boolean caller still works")
    }

    @Test fun observedHitIsIndependentOfTextChunkCount() {
        val zero = CapFake(ChatCapStatus.HIT)
        val few = CapFake(ChatCapStatus.HIT, listOf("a", "b"))

        zero.completeChat("", emptyList()) { }
        few.completeChat("", emptyList()) { }

        assertEquals(ChatCapStatus.HIT, zero.chatCapStatus(), "zero chunks do not prove NOT_HIT")
        assertEquals(ChatCapStatus.HIT, few.chatCapStatus())
    }

    @Test fun observedNotHitIsNotDerivedFromManyChunks() {
        val many = CapFake(ChatCapStatus.NOT_HIT, List(300) { "x" })

        many.completeChat("", emptyList()) { }

        assertEquals(ChatCapStatus.NOT_HIT, many.chatCapStatus())
    }

    @Test fun measuredMappingRequiresCleanOutcome() {
        assertEquals(ChatCapStatus.HIT, LlamaEngine.capStatusFor(true, cancelled = false, observed = true, measuredStatus = 0))
        assertEquals(ChatCapStatus.NOT_HIT, LlamaEngine.capStatusFor(false, cancelled = false, observed = true, measuredStatus = 0))
        assertEquals(ChatCapStatus.NOT_HIT, LlamaEngine.capStatusFor(true, cancelled = false, observed = true, measuredStatus = 3))
    }

    @Test fun cancellationFatalClampAndMissingMeasurementAreUnknown() {
        for (status in listOf(1, 2, 4, 5)) {
            assertEquals(
                ChatCapStatus.UNKNOWN,
                LlamaEngine.capStatusFor(true, cancelled = false, observed = true, measuredStatus = status),
                "measured status $status is not a clean completion",
            )
        }
        assertEquals(ChatCapStatus.UNKNOWN, LlamaEngine.capStatusFor(true, cancelled = false, observed = true, measuredStatus = null))
        assertEquals(ChatCapStatus.UNKNOWN, LlamaEngine.capStatusFor(true, cancelled = true, observed = true, measuredStatus = 0))
        assertEquals(ChatCapStatus.UNKNOWN, LlamaEngine.capStatusFor(true, cancelled = false, observed = false, measuredStatus = 0))
    }

    @Test fun wrappedLegacyBooleanIsIndependentOfTheNewStatus() {
        val legacy = object : InferenceEngine {
            override val loadedModelId: String? = "legacy"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = ""
            override fun lastHitTokenCap(): Boolean = true
        }
        val wrapper = CoordinatedInferenceEngine(legacy)

        assertTrue(wrapper.lastHitTokenCap(), "legacy true must survive the wrapper")
        assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus())

        wrapper.complete("prompt")
        assertTrue(wrapper.lastHitTokenCap(), "raw completion keeps the legacy boolean")
        assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus(), "raw completion has no new observed reason")
    }

    @Test fun explicitCancellationDuringStatusReadCannotRepublishHit() {
        for (owned in listOf(false, true)) {
            val underlying = StatusLatchedEngine()
            val wrapper = CoordinatedInferenceEngine(underlying)
            val failure = AtomicReference<Throwable?>()
            val completion = Thread {
                try {
                    if (owned) wrapper.completeChatOwned("", emptyList(), { true }) { }
                    else wrapper.completeChat("", emptyList()) { }
                } catch (error: Throwable) { failure.set(error) }
            }
            completion.start()
            try {
                assertTrue(underlying.statusEntered.await(5, TimeUnit.SECONDS), "status must be suspended")
                wrapper.requestCancel()
                assertEquals(0L, underlying.cancelEntered.count, "cancellation must reach the underlying engine")
                assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus())
            } finally {
                underlying.releaseStatus.countDown()
                completion.join(5000)
            }
            assertFalse(completion.isAlive, "completion must settle after the status gate opens")
            assertEquals(null, failure.get())
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus(), "the latched HIT belongs to a canceled run")
            assertTrue(wrapper.lastHitTokenCap(), "legacy boolean remains independently delegated")
        }
    }

    @Test fun explicitCancellationInvalidatesAnAlreadyPublishedHit() {
        val wrapper = CoordinatedInferenceEngine(CapFake(ChatCapStatus.HIT).apply { legacyHit = true })
        wrapper.completeChat("", emptyList()) { }
        assertEquals(ChatCapStatus.HIT, wrapper.chatCapStatus())
        wrapper.requestCancel()
        assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus())
        assertTrue(wrapper.lastHitTokenCap())
    }

    @Test fun specialistSuspensionAndRestorationDoNotLeakThePreviousStatus() {
        val (model, file) = tinyModel()
        try {
            val underlying = CapFake(ChatCapStatus.HIT)
            val wrapper = CoordinatedInferenceEngine(underlying)
            wrapper.load(model, file.path)
            wrapper.completeChatOwned("", emptyList(), { true }) { }
            assertEquals(ChatCapStatus.HIT, wrapper.chatCapStatus())

            val lease = wrapper.suspendForSpecialist()
            assertTrue(wrapper.isSuspendedForSpecialist)
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus())

            lease.resume()
            assertFalse(wrapper.isSuspendedForSpecialist)
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus(), "restoration must not leak the prior main status")

            underlying.status = ChatCapStatus.NOT_HIT
            wrapper.completeChatOwned("", emptyList(), { true }) { }
            assertEquals(ChatCapStatus.NOT_HIT, wrapper.chatCapStatus())
        } finally {
            file.delete()
        }
    }

    @Test fun successiveRunsDoNotRetainThePreviousStatus() {
        val (model, file) = tinyModel()
        try {
            val underlying = CapFake(ChatCapStatus.HIT)
            val wrapper = CoordinatedInferenceEngine(underlying)
            wrapper.load(model, file.path)

            wrapper.completeChatOwned("", emptyList(), { true }) { }
            assertEquals(ChatCapStatus.HIT, wrapper.chatCapStatus())

            underlying.status = ChatCapStatus.UNKNOWN
            wrapper.completeChatOwned("", emptyList(), { true }) { }
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus())
        } finally {
            file.delete()
        }
    }

    @Test fun automaticModelTransactionInvalidatesPreviousHitOnSuccessAndFailure() {
        val (model, file) = tinyModel()
        try {
            val underlying = CapFake(ChatCapStatus.HIT)
            val wrapper = CoordinatedInferenceEngine(underlying)
            wrapper.load(model, file.path)
            wrapper.completeChatOwned("", emptyList(), { true }) { }
            assertEquals(ChatCapStatus.HIT, wrapper.chatCapStatus())

            val next = model.copy(id = "cap-next-${file.name}")
            assertTrue(wrapper.activateInstalledIfIdle(next, file.path, null, null, null) { true })
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus(), "a successful switch must clear the old hit")

            wrapper.completeChatOwned("", emptyList(), { true }) { }
            assertEquals(ChatCapStatus.HIT, wrapper.chatCapStatus())

            underlying.failLoad = true
            assertFalse(wrapper.activateInstalledIfIdle(next, file.path, null, null, null) { true })
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus(), "a failed switch must clear the old hit")
        } finally {
            file.delete()
        }
    }

    @Test fun staleCompletionCannotRepublishHitAfterSpecialistInvalidation() {
        val (model, file) = tinyModel()
        try {
            val underlying = LatchedEngine()
            val wrapper = CoordinatedInferenceEngine(underlying)
            wrapper.load(model, file.path)
            val lease = AtomicReference<SpecialistInferenceLease?>()

            val completion = Thread {
                wrapper.completeChatOwned("", emptyList(), { true }) { }
            }
            completion.start()
            assertTrue(underlying.entered.await(5, TimeUnit.SECONDS), "completion must be admitted")

            val suspension = Thread {
                try { lease.set(wrapper.suspendForSpecialist()) } catch (_: Throwable) { }
            }
            suspension.start()
            assertTrue(underlying.cancelEntered.await(5, TimeUnit.SECONDS), "suspension must invalidate before joining")

            underlying.release.countDown()
            completion.join(5000)
            suspension.join(5000)
            assertFalse(completion.isAlive, "completion must leave the admitted boundary")
            assertFalse(suspension.isAlive, "suspension must finish")

            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus())
            lease.get()?.resume()
            assertEquals(ChatCapStatus.UNKNOWN, wrapper.chatCapStatus(), "the stale completion must not republish after restoration")
        } finally {
            file.delete()
        }
    }
}
