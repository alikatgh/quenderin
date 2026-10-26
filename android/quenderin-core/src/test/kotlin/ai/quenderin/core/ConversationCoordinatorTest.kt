package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Deterministic lifecycle checks executed by the hosted Gradle/JUnit core test task. */
class ConversationCoordinatorTest {
    /** Invokes the lifecycle action after the first flushed token, then deliberately emits a late tail. */
    private class StreamingEngine : InferenceEngine {
        override val loadedModelId: String = "controlled-stream"
        var onStream: () -> Unit = {}
        var calls = 0
        var cancellations = 0

        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = error("Expected structured streaming completion")
        override fun requestCancel() { cancellations++ }
        override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
            calls++
            onToken("partial")
            onStream()
            onToken(" tail")
            return "partial tail"
        }
    }

    private class RecordingPersistence(
        private val store: InMemoryConversationPersistence = InMemoryConversationPersistence(),
    ) : ConversationPersistence by store {
        var transcriptWrites = 0
        override fun saveTranscript(id: String, messages: List<ChatMessage>) {
            transcriptWrites++
            store.saveTranscript(id, messages)
        }
        fun texts(id: String): List<String> = loadTranscript(id).map { it.text }
    }

    private class Fixture {
        val engine = StreamingEngine()
        val chat = ChatModel(engine)
        val persistence = RecordingPersistence()
        private var nextId = 0
        val coordinator = ConversationCoordinator(chat, persistence, now = { 42L }, makeId = { "chat-${++nextId}" })
        fun texts(): List<String> = chat.messages.map { it.text }
    }

    @Test fun stopBeforeAdmissionRejectsQueuedTurnWithoutCallingEngine() {
        val f = Fixture()
        val id = checkNotNull(f.coordinator.currentId)
        f.coordinator.saveDraft(id, "question", emptyList())
        val admission = f.chat.captureTurnAdmission()

        f.chat.stopGenerating() // Composer is busy, but the queued background send has not entered ChatModel.

        assertFailsWith<AutomaticSelectionChangedException> {
            f.chat.send("question", admission = admission)
        }
        assertEquals(0, f.engine.calls)
        assertEquals(0, f.engine.cancellations, "An unstarted turn has no native decode to cancel")
        assertTrue(f.chat.messages.isEmpty())
        assertFalse(f.chat.isGenerating)
        assertEquals("question", f.coordinator.draft(id).text)

        // Stop only invalidates old admission; a new explicit Send remains usable.
        f.chat.send("fresh question", admission = f.chat.captureTurnAdmission())
        assertEquals(1, f.engine.calls)
        assertEquals(listOf("fresh question", "partial tail"), f.texts())
    }

    @Test fun backMidstreamCannotPersistPartialAfterCompletionOrReopen() {
        val f = Fixture()
        val id = checkNotNull(f.coordinator.currentId)
        f.engine.onStream = {
            assertEquals(listOf("question", "partial"), f.texts())
            f.chat.invalidatePreparedTurns() // ChatScreen Back runs this before MainTabs persists.
            f.coordinator.persist()
            assertEquals(listOf("question"), f.persistence.texts(id))
        }

        f.chat.send("question")
        f.coordinator.persist() // Delayed completion/finally must not resurrect the abandoned answer.
        f.coordinator.persist()
        f.coordinator.open(id)

        assertEquals(listOf("question"), f.persistence.texts(id))
        assertEquals(listOf("question"), f.texts())
        assertEquals(1, f.persistence.transcriptWrites)
        assertFalse(f.chat.isGenerating)
    }

    @Test fun newMidstreamPreservesEarlierTurnsWithoutSavingThePartial() {
        val f = Fixture()
        f.chat.send("earlier question")
        f.coordinator.persist()
        val oldId = checkNotNull(f.coordinator.currentId)
        val expected = listOf("earlier question", "partial tail", "next question")
        f.engine.onStream = {
            f.coordinator.startNew()
            assertEquals(expected, f.persistence.texts(oldId))
            assertTrue(f.chat.messages.isEmpty())
        }

        f.chat.send("next question")
        f.coordinator.persist()
        assertTrue(f.chat.messages.isEmpty())
        assertTrue(f.coordinator.currentId != oldId)
        assertEquals(expected, f.persistence.texts(oldId))
        assertEquals(2, f.persistence.transcriptWrites)
        f.coordinator.open(oldId)
        assertEquals(expected, f.texts())
        assertFalse(f.chat.isGenerating)
    }

    @Test fun openMidstreamKeepsBothConversationsFreeOfTheAbandonedPartial() {
        val f = Fixture()
        f.chat.send("saved question")
        f.coordinator.persist()
        val savedId = checkNotNull(f.coordinator.currentId)
        val saved = f.texts()
        f.coordinator.startNew()
        val outgoingId = checkNotNull(f.coordinator.currentId)
        f.engine.onStream = { f.coordinator.open(savedId) }

        f.chat.send("outgoing question")
        f.coordinator.persist()
        f.coordinator.persist()

        assertEquals(savedId, f.coordinator.currentId)
        assertEquals(saved, f.texts())
        assertEquals(saved, f.persistence.texts(savedId))
        assertEquals(listOf("outgoing question"), f.persistence.texts(outgoingId))
        assertEquals(2, f.persistence.transcriptWrites)
        f.coordinator.open(outgoingId)
        assertEquals(listOf("outgoing question"), f.texts())
    }

    @Test fun explicitStopKeepsPartialAndPersistsExactlyOnceAcrossReopen() {
        val f = Fixture()
        val id = checkNotNull(f.coordinator.currentId)
        val expected = listOf("question", "partial")
        f.engine.onStream = {
            f.chat.stopGenerating()
            f.chat.stopGenerating() // Repeated Stop must keep the already settled partial.
            assertEquals(1, f.engine.cancellations)
            f.coordinator.persist()
            assertEquals(expected, f.persistence.texts(id))
        }

        f.chat.send("question")
        f.coordinator.persist()
        f.coordinator.persist()
        f.coordinator.open(id)

        assertEquals(expected, f.texts())
        assertEquals(expected, f.persistence.texts(id))
        assertEquals(1, f.persistence.transcriptWrites)
        assertFalse(f.chat.isGenerating)
    }

    @Test fun repeatedPersistBetweenTurnsDoesNotInvalidatePreparedAdmission() {
        val f = Fixture()
        f.chat.send("first question")
        f.coordinator.persist()
        val admission = f.chat.captureTurnAdmission()

        f.coordinator.persist()
        f.coordinator.persist()
        assertEquals(1, f.persistence.transcriptWrites)
        f.chat.send("second question", admission = admission)
        f.coordinator.persist()

        assertEquals(2, f.engine.calls)
        assertEquals(2, f.persistence.transcriptWrites)
        assertEquals(listOf("first question", "partial tail", "second question", "partial tail"), f.texts())
    }

    @Test fun idleStopDoesNotSettleAPartialFromAFailedSend() {
        val f = Fixture()
        val id = checkNotNull(f.coordinator.currentId)
        f.engine.onStream = { error("Synthetic stream failure") }
        assertFailsWith<IllegalStateException> { f.chat.send("question") }
        assertFalse(f.chat.isGenerating)
        assertEquals(listOf("question", "partial"), f.texts())

        f.chat.stopGenerating()

        assertEquals(listOf("question"), f.chat.completedMessages().map { it.text })
        assertEquals(0, f.engine.cancellations)
        f.coordinator.persist()
        assertEquals(listOf("question"), f.persistence.texts(id))
        assertEquals(listOf("question"), f.texts())
    }
}
