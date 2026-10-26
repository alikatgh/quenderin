package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertNull
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Explicit Stop settles the text accepted BEFORE the Stop exactly once, while retaining transcript
 * ownership until that settle. A concurrent Send is a no-op; navigation abandons the partial and
 * prevents the late write; persistence uses an atomic completed/revision snapshot.
 *
 * Runs through the hosted Gradle/JUnit task and the bounded local JVM test runner.
 */
class StopSettlementTest {

    private val wallParagraph =
        "Quender was a forest elf, a member of the slender and agile forest elves of the deep wood."

    private class StopEngine(
        private val firstPieces: List<String>,
        private val laterReply: String = "next reply",
        private val firstReply: String? = null,
        private val latePieces: List<String> = emptyList(),
    ) : InferenceEngine {
        var onFirst: (() -> Unit)? = null
        var calls = 0
        var cancellations = 0
        override val loadedModelId: String? = "stop-engine"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = error("structured completion expected")
        override fun requestCancel() { cancellations++ }
        override fun completeChat(
            systemPrompt: String,
            history: List<ChatMessage>,
            onToken: (String) -> Unit,
        ): String {
            calls++
            if (calls > 1) {
                onToken(laterReply)
                return laterReply
            }
            for (piece in firstPieces) onToken(piece)
            onFirst?.invoke()
            for (piece in latePieces) onToken(piece)
            return firstReply ?: firstPieces.joinToString("")
        }
    }

    private class ImmediateEngine(private val reply: String) : InferenceEngine {
        override val loadedModelId: String? = "immediate"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = reply
    }

    private class CountingPersistence : ConversationPersistence {
        private val store = InMemoryConversationPersistence()
        var writes = 0
        override fun saveTranscript(id: String, messages: List<ChatMessage>) {
            writes++
            store.saveTranscript(id, messages)
        }
        override fun loadTranscript(id: String): List<ChatMessage> = store.loadTranscript(id)
        override fun deleteTranscript(id: String) = store.deleteTranscript(id)
        override fun saveIndex(summaries: List<ConversationSummary>) = store.saveIndex(summaries)
        override fun loadIndex(): List<ConversationSummary> = store.loadIndex()
    }

    private class FlakyPersistence : ConversationPersistence {
        private val store = InMemoryConversationPersistence()
        var failNext = true
        override fun saveTranscript(id: String, messages: List<ChatMessage>) {
            if (failNext) {
                failNext = false
                error("synthetic disk failure")
            }
            store.saveTranscript(id, messages)
        }
        override fun loadTranscript(id: String): List<ChatMessage> = store.loadTranscript(id)
        override fun deleteTranscript(id: String) = store.deleteTranscript(id)
        override fun saveIndex(summaries: List<ConversationSummary>) = store.saveIndex(summaries)
        override fun loadIndex(): List<ConversationSummary> = store.loadIndex()
    }

    @Test fun stopSettlesTheCollapsedPreStopWall() {
        val wall = listOf(wallParagraph, wallParagraph, wallParagraph).joinToString("\n\n")
        val engine = StopEngine(listOf(wall))
        val chat = ChatModel(engine)
        engine.onFirst = { chat.stopGenerating() }

        val result = chat.send("question")

        assertEquals(wallParagraph, result)
        assertEquals(wallParagraph, chat.messages.last().text)
        assertEquals(1, engine.cancellations)
        assertEquals(1, engine.calls)
        assertFalse(chat.isGenerating)
        assertFalse(chat.lastHitTokenCap)
    }

    @Test fun stopKeepsABufferedTailAcceptedBeforeTheStop() {
        val engine = StopEngine(listOf("part", "ial"))
        val chat = ChatModel(engine)
        engine.onFirst = { chat.stopGenerating() }

        val result = chat.send("question")

        assertEquals("partial", result)
        assertEquals("partial", chat.messages.last().text)
    }

    @Test fun sendDuringSettlementIsANoOpAndSendAfterwardAppends() {
        val engine = StopEngine(listOf("partial"))
        val chat = ChatModel(engine)
        var duringSettlement = "unset"
        engine.onFirst = {
            chat.stopGenerating()
            duringSettlement = chat.send("next")
        }

        chat.send("question")

        assertEquals("", duringSettlement)
        assertEquals(1, engine.calls)
        assertEquals(listOf("question", "partial"), chat.messages.map { it.text })

        val after = chat.send("next")
        assertEquals("next reply", after)
        assertEquals(
            listOf("question", "partial", "next", "next reply"),
            chat.messages.map { it.text },
        )
    }

    @Test fun zeroTokenStopLeavesTheSameEmptyBubbleWithoutANotice() {
        val engine = StopEngine(emptyList())
        val chat = ChatModel(engine)
        engine.onFirst = { chat.stopGenerating() }

        val result = chat.send("question")

        assertEquals("", result)
        assertEquals("", chat.messages.last().text)
        assertEquals(2, chat.messages.size)
    }

    @Test fun stopThenNewChatAbandonsThePartialAndTheLateSettleWritesNothing() {
        val persistence = InMemoryConversationPersistence()
        val engine = StopEngine(listOf("partial"))
        val chat = ChatModel(engine)
        val coordinator = ConversationCoordinator(chat, persistence, now = { 1L }, makeId = { "chat" })
        val oldId = coordinator.currentId!!
        engine.onFirst = {
            chat.stopGenerating()
            coordinator.startNew()
        }

        chat.send("question")

        assertEquals(listOf("question"), persistence.loadTranscript(oldId).map { it.text })
        assertTrue(chat.messages.isEmpty(), "the new chat must not receive the abandoned partial")
        assertEquals("", chat.completedMessages().joinToString(""))
    }

    @Test fun persistDuringSettlementGetsOneCorrectiveSave() {
        val persistence = CountingPersistence()
        val wall = listOf(wallParagraph, wallParagraph, wallParagraph).joinToString("\n\n")
        val engine = StopEngine(listOf(wall))
        val chat = ChatModel(engine)
        val coordinator = ConversationCoordinator(chat, persistence, now = { 2L }, makeId = { "chat" })
        val id = coordinator.currentId!!
        var duringSettlement: List<String>? = null
        engine.onFirst = {
            chat.stopGenerating()
            coordinator.persist()
            duringSettlement = persistence.loadTranscript(id).map { it.text }
        }

        chat.send("question")
        coordinator.persist()   // corrective save: same count, changed text revision
        coordinator.open(id)

        assertEquals(listOf("question", wall), duringSettlement)
        assertEquals(listOf("question", wallParagraph), chat.messages.map { it.text })
        assertEquals(2, persistence.writes, "one interim save + one corrective save")
        assertEquals(listOf("question", wallParagraph), persistence.loadTranscript(id).map { it.text })
    }

    @Test fun activeStopRejectsAnAdmissionCapturedBeforeIt() {
        val engine = StopEngine(listOf("partial"))
        val chat = ChatModel(engine)
        var captured: ChatTurnAdmission? = null
        engine.onFirst = {
            captured = chat.captureTurnAdmission()
            chat.stopGenerating()
        }

        chat.send("question")

        assertFailsWith<AutomaticSelectionChangedException> {
            chat.send("queued", admission = captured!!)
        }
        assertEquals(1, engine.calls)
    }

    @Test fun saveFailureDoesNotAdvanceTheRevisionAndRetryPersists() {
        val persistence = FlakyPersistence()
        val chat = ChatModel(ImmediateEngine("answer"))
        val coordinator = ConversationCoordinator(chat, persistence, now = { 3L }, makeId = { "chat" })
        val id = coordinator.currentId!!

        chat.send("question")
        assertFailsWith<IllegalStateException> { coordinator.persist() }
        assertTrue(persistence.loadTranscript(id).isEmpty(), "a failed save must not be recorded as durable")

        coordinator.persist()

        assertEquals(listOf("question", "answer"), persistence.loadTranscript(id).map { it.text })
    }

    @Test fun queuedUiAcceptsTheCollapsedFinalSnapshotAfterStop() {
        val wall = List(3) { wallParagraph }.joinToString("\n\n")
        val engine = StopEngine(listOf(wall))
        val chat = ChatModel(engine)
        val queuedMessages = mutableListOf<Pair<Long, List<ChatMessage>>>()
        val queuedPhases = mutableListOf<Pair<Long, GenerationPhase>>()
        chat.onRevisionChange = { revision, messages -> queuedMessages += revision to messages }
        chat.onRevisionPhaseChange = { revision, phase -> queuedPhases += revision to phase }
        engine.onFirst = { chat.stopGenerating() }

        chat.send("question")

        // Compose consumes these callbacks later and rejects events whose revision is no longer current.
        val visible = queuedMessages.filter { chat.isRevisionCurrent(it.first) }.lastOrNull()?.second
        val phase = queuedPhases.filter { chat.isRevisionCurrent(it.first) }.lastOrNull()?.second
        assertEquals(listOf("question", wallParagraph), visible?.map { it.text })
        assertEquals(GenerationPhase.IDLE, phase)
        assertEquals(chat.messages, visible)
    }

    @Test fun supersededSendCannotClearANewerTurnsStopOrAdmitItsLateToken() {
        val firstStarted = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val releaseSecond = CountDownLatch(1)
        val calls = AtomicInteger()
        val failure = AtomicReference<Throwable?>()
        val engine = object : InferenceEngine {
            override val loadedModelId: String = "two-owned-turns"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = error("structured completion expected")
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                if (calls.incrementAndGet() == 1) {
                    onToken("first prefix")
                    firstStarted.countDown()
                    check(releaseFirst.await(5, TimeUnit.SECONDS)) { "first gate timed out" }
                    return "first prefix"
                }
                onToken("second prefix")
                secondStarted.countDown()
                check(releaseSecond.await(5, TimeUnit.SECONDS)) { "second gate timed out" }
                onToken(" late token")
                return "second prefix late token"
            }
        }
        val chat = ChatModel(engine)
        val first = thread(isDaemon = true, name = "stop-superseded-first") {
            try { chat.send("first question") } catch (t: Throwable) { failure.compareAndSet(null, t) }
        }
        var second: Thread? = null
        try {
            assertTrue(firstStarted.await(5, TimeUnit.SECONDS))
            chat.invalidatePreparedTurns()
            second = thread(isDaemon = true, name = "stop-current-second") {
                try { chat.send("second question") } catch (t: Throwable) { failure.compareAndSet(null, t) }
            }
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
            chat.stopGenerating()
            releaseFirst.countDown()
            first.join(5_000) // Force the superseded finally to run while the second turn is stopped.
            assertFalse(first.isAlive)
            assertTrue(chat.isGenerating, "the old finally must not release the current turn")
            releaseSecond.countDown()
            second.join(5_000)
            assertFalse(second.isAlive)
        } finally {
            releaseFirst.countDown()
            releaseSecond.countDown()
            first.join(5_000)
            second?.join(5_000)
        }

        assertNull(failure.get())
        assertEquals(listOf("first question", "second question", "second prefix"), chat.messages.map { it.text })
        assertFalse(chat.isGenerating)
    }

    @Test fun stopThenInterimPersistThenNewDurablyRemovesThePartial() {
        val persistence = CountingPersistence()
        val engine = StopEngine(listOf("partial"))
        val chat = ChatModel(engine)
        var nextId = 0
        val coordinator = ConversationCoordinator(chat, persistence, now = { 4L }, makeId = { "chat-${++nextId}" })
        val oldId = checkNotNull(coordinator.currentId)
        engine.onFirst = {
            chat.stopGenerating()
            coordinator.persist()
            assertEquals(listOf("question", "partial"), persistence.loadTranscript(oldId).map { it.text })
            coordinator.startNew()
            assertEquals(listOf("question"), persistence.loadTranscript(oldId).map { it.text })
        }

        chat.send("question")
        coordinator.persist()
        assertTrue(chat.messages.isEmpty())
        assertEquals(2, persistence.writes, "navigation must replace the interim durable Stop partial")
        coordinator.open(oldId)
        assertEquals(listOf("question"), chat.messages.map { it.text })
    }

    @Test fun zeroCallbackStopNeverAdoptsTheLateNonStreamingReturn() {
        val engine = StopEngine(emptyList(), firstReply = "late engine return")
        val chat = ChatModel(engine)
        engine.onFirst = { chat.stopGenerating() }

        assertEquals("", chat.send("question"))
        assertEquals(listOf("question", ""), chat.messages.map { it.text })
        assertEquals(1, engine.cancellations)
    }

    @Test fun repeatedStopRejectsNewQueuedAdmissionsAndKeepsOnlyThePreStopBuffer() {
        val engine = StopEngine(listOf("part", "ial"), latePieces = listOf(" late token"))
        val chat = ChatModel(engine)
        lateinit var queuedAfterFirstStop: ChatTurnAdmission
        engine.onFirst = {
            chat.stopGenerating()
            queuedAfterFirstStop = chat.captureTurnAdmission()
            chat.stopGenerating()
            assertEquals(1, engine.cancellations)
        }

        assertEquals("partial", chat.send("question"))
        assertEquals(listOf("question", "partial"), chat.messages.map { it.text })
        assertEquals(1, engine.cancellations)
        assertFailsWith<AutomaticSelectionChangedException> {
            chat.send("queued", admission = queuedAfterFirstStop)
        }
        assertEquals(1, engine.calls)
    }

}
