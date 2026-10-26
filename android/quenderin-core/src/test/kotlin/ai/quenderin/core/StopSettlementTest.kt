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
        var errorAfterHook: Exception? = null
        var secondHistory: List<String> = emptyList()
        var calls = 0
        var cancellations = 0
        var hitTokenCap = false
        override val loadedModelId: String? = "stop-engine"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = error("structured completion expected")
        override fun requestCancel() { cancellations++ }
        override fun chatCapStatus(): ChatCapStatus = if (hitTokenCap) ChatCapStatus.HIT else ChatCapStatus.NOT_HIT
        override fun completeChat(
            systemPrompt: String,
            history: List<ChatMessage>,
            onToken: (String) -> Unit,
        ): String {
            calls++
            if (calls > 1) {
                secondHistory = history.map { it.text }
                onToken(laterReply)
                return laterReply
            }
            for (piece in firstPieces) onToken(piece)
            onFirst?.invoke()
            errorAfterHook?.let { throw it }
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

    @Test fun stopDuringAdmissionSkipsCompletionAndSettlesTheEmptyBubble() {
        val engine = StopEngine(listOf("next reply"))
        engine.hitTokenCap = true
        val chat = ChatModel(engine)
        var assistantId: Long? = null

        val result = chat.send("question", onAdmitted = {
            assistantId = chat.messages.last().id
            chat.stopGenerating()
        })

        assertEquals("", result)
        assertEquals(0, engine.calls, "Stop during metadata I/O must prevent completion entry")
        assertEquals(1, engine.cancellations)
        assertEquals(listOf("question", ""), chat.messages.map { it.text })
        assertEquals(assistantId, chat.messages.last().id)
        assertEquals(chat.messages, chat.completedMessages(), "the empty Stop turn must finish ownership")
        assertEquals(chat.messages, chat.persistSnapshot().first)
        assertFalse(chat.lastHitTokenCap)
        assertFalse(chat.isGenerating)

        assertEquals("next reply", chat.send("next"))
        assertEquals(1, engine.calls)
        assertEquals(listOf("question", "", "next", "next reply"), chat.messages.map { it.text })
    }

    @Test fun stopBetweenEngineAdmissionChecksRejectsTheNativeWork() {
        val engine = object : InferenceEngine {
            var onCancellationReset: (() -> Unit)? = null
            var cancellationRequested = false
            var completionEntries = 0
            override val loadedModelId: String = "admission-reset"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = error("structured completion expected")
            override fun requestCancel() { cancellationRequested = true }
            override fun chatCapStatus(): ChatCapStatus = ChatCapStatus.HIT
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                completionEntries++
                onToken("next reply")
                return "next reply"
            }
            override fun completeChatOwned(systemPrompt: String, history: List<ChatMessage>, isCurrent: () -> Boolean, onToken: (String) -> Unit): String {
                // Match LlamaEngine's recheck after it resets the native cancellation flag.
                if (!isCurrent()) return ""
                cancellationRequested = false
                onCancellationReset?.invoke()
                if (!isCurrent()) { cancellationRequested = true; return "" }
                return completeChat(systemPrompt, history, onToken)
            }
        }
        val chat = ChatModel(engine)
        engine.onCancellationReset = {
            engine.onCancellationReset = null
            chat.stopGenerating()
        }

        assertEquals("", chat.send("question"))
        assertEquals(0, engine.completionEntries)
        assertTrue(engine.cancellationRequested)
        assertEquals(listOf("question", ""), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertFalse(chat.lastHitTokenCap)
        assertFalse(chat.isGenerating)

        assertEquals("next reply", chat.send("next"))
        assertEquals(1, engine.completionEntries)
        assertFalse(engine.cancellationRequested)
    }

    @Test fun stopDuringTokenCapReadSettlesEmptyWithoutANoticeOrContinue() {
        val capReadStarted = CountDownLatch(1)
        val releaseCapRead = CountDownLatch(1)
        val result = AtomicReference<String?>()
        val failure = AtomicReference<Throwable?>()
        val engine = object : InferenceEngine {
            var completions = 0
            override val loadedModelId: String = "blocked-cap-read"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String {
                completions++
                return if (completions == 1) "" else "next reply"
            }
            override fun chatCapStatus(): ChatCapStatus {
                if (completions == 1) {
                    capReadStarted.countDown()
                    check(releaseCapRead.await(5, TimeUnit.SECONDS)) { "token-cap gate timed out" }
                }
                return ChatCapStatus.HIT
            }
        }
        val chat = ChatModel(engine)
        val send = thread(isDaemon = true, name = "stop-during-token-cap-read") {
            try { result.set(chat.send("question")) } catch (t: Throwable) { failure.set(t) }
        }
        try {
            assertTrue(capReadStarted.await(5, TimeUnit.SECONDS))
            chat.stopGenerating()
        } finally {
            releaseCapRead.countDown()
            send.join(5_000)
        }

        assertFalse(send.isAlive)
        assertNull(failure.get())
        assertEquals("", result.get())
        assertEquals(listOf("question", ""), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertEquals(chat.messages, chat.persistSnapshot().first)
        assertFalse(chat.lastHitTokenCap)
        assertFalse(chat.isGenerating)

        assertEquals("next reply", chat.send("next"))
        assertTrue(chat.lastHitTokenCap, "the next unstopped turn still receives its own cap signal")
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

    @Test fun stopPreservesAcceptedTextWhenCompletionThrows() {
        val engine = StopEngine(listOf("part", "ial"))
        val chat = ChatModel(engine)
        engine.onFirst = { chat.stopGenerating() }
        engine.errorAfterHook = IllegalStateException("engine cancelled")

        val result = chat.send("question")

        assertEquals("partial", result)
        assertEquals(listOf("question", "partial"), chat.messages.map { it.text })
        assertEquals(1, engine.cancellations)
        assertFalse(chat.lastHitTokenCap, "a stopped error must not offer Continue")
        assertFalse(chat.isGenerating)
    }

    @Test fun zeroTokenStopThenCompletionErrorStaysEmpty() {
        val engine = StopEngine(emptyList())
        val chat = ChatModel(engine)
        engine.onFirst = { chat.stopGenerating() }
        engine.errorAfterHook = IllegalStateException("engine cancelled")

        assertEquals("", chat.send("question"))
        assertEquals(listOf("question", ""), chat.messages.map { it.text })
    }

    @Test fun unstoppedCompletionErrorStillPropagates() {
        val engine = StopEngine(listOf("part"))
        val chat = ChatModel(engine)
        engine.errorAfterHook = IllegalStateException("genuine engine failure")

        assertFailsWith<IllegalStateException> { chat.send("question") }

        assertFalse(chat.isGenerating)
        assertEquals(listOf("part"), chat.messages.drop(1).map { it.text })
        assertEquals(listOf("question"), chat.completedMessages().map { it.text })
    }

    @Test fun staleThrowingSendCannotTouchTheNewTurn() {
        val persistence = InMemoryConversationPersistence()
        val engine = StopEngine(listOf("A-part"))
        val chat = ChatModel(engine)
        var ids = 0
        val coordinator = ConversationCoordinator(chat, persistence, now = { 4L }, makeId = { "chat-${++ids}" })
        val oldId = coordinator.currentId!!
        var bResult = ""
        engine.onFirst = {
            coordinator.startNew()            // true navigation: save A's user turn, then reset
            bResult = chat.send("B")
        }
        engine.errorAfterHook = IllegalStateException("stale A failed")

        assertEquals("", chat.send("A"))
        assertEquals("next reply", bResult)
        assertEquals(listOf("B", "next reply"), chat.messages.map { it.text })
        assertEquals(listOf("A"), persistence.loadTranscript(oldId).map { it.text })
    }

    @Test fun stoppedErrorPersistsAndReopensCollapsedTextExactlyOnce() {
        val persistence = CountingPersistence()
        val engine = StopEngine(listOf("part", "ial"))
        val chat = ChatModel(engine)
        val coordinator = ConversationCoordinator(chat, persistence, now = { 5L }, makeId = { "chat" })
        val id = coordinator.currentId!!
        engine.onFirst = { chat.stopGenerating() }
        engine.errorAfterHook = IllegalStateException("engine cancelled")

        assertEquals("partial", chat.send("question"))
        coordinator.persist()
        coordinator.open(id)

        assertEquals(listOf("question", "partial"), chat.messages.map { it.text })
        assertEquals(listOf("question", "partial"), persistence.loadTranscript(id).map { it.text })
        assertEquals(1, persistence.writes)
    }

    @Test fun jobCancellationDuringAdmissionSkipsCompletionAndRemovesTheEmptySlot() {
        val engine = StopEngine(listOf("next reply"))
        val chat = ChatModel(engine)
        var cancelled = false

        assertFailsWith<java.util.concurrent.CancellationException> {
            chat.send("question", isCancelled = { cancelled }, onAdmitted = { cancelled = true })
        }

        assertEquals(0, engine.calls)
        assertEquals(listOf("question"), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertEquals(chat.messages, chat.persistSnapshot().first)
        assertFalse(chat.isGenerating)
        assertFalse(chat.lastHitTokenCap)
        assertEquals("next reply", chat.send("next"))
    }

    @Test fun jobCancellationAfterTheFirstFlushRemovesThePartialBeforePersistence() {
        val persistence = InMemoryConversationPersistence()
        val engine = StopEngine(listOf("part", "ial"), latePieces = listOf(" late token"))
        val chat = ChatModel(engine)
        val coordinator = ConversationCoordinator(chat, persistence, now = { 7L }, makeId = { "chat" })
        val id = coordinator.currentId!!
        var cancelled = false
        val published = mutableListOf<List<String>>()
        chat.onChange = { messages ->
            published += messages.map { it.text }
            if (messages.lastOrNull()?.text == "part") cancelled = true
        }

        assertFailsWith<java.util.concurrent.CancellationException> {
            chat.send("question", isCancelled = { cancelled })
        }

        assertEquals(1, engine.cancellations, "a cancelled callback signals the engine once without throwing through it")
        assertEquals(listOf("question"), published.last(), "publish the owned assistant removal")
        assertEquals(listOf("question"), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertFalse(chat.isGenerating)
        coordinator.persist()
        assertEquals(listOf("question"), persistence.loadTranscript(id).map { it.text })

        assertEquals("next reply", chat.send("next"))
        assertEquals(listOf("question", "next"), engine.secondHistory)
        coordinator.persist()
        coordinator.open(id)
        assertEquals(listOf("question", "next", "next reply"), chat.messages.map { it.text })
    }

    @Test fun zeroTokenJobCancellationRemovesTheBubbleWithoutAdoptingTheLateReturn() {
        val engine = StopEngine(emptyList(), firstReply = "late engine return")
        engine.hitTokenCap = true
        val chat = ChatModel(engine)
        var cancelled = false
        engine.onFirst = { cancelled = true }

        assertFailsWith<java.util.concurrent.CancellationException> {
            chat.send("question", isCancelled = { cancelled })
        }

        assertEquals(listOf("question"), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertEquals(chat.messages, chat.persistSnapshot().first)
        assertFalse(chat.isGenerating)
        assertFalse(chat.lastHitTokenCap)
        assertEquals("next reply", chat.send("next"))
    }

    @Test fun explicitStopBeforeJobCancellationStillSettlesTheAcceptedBuffer() {
        val engine = StopEngine(listOf("part", "ial"), latePieces = listOf(" late token"))
        engine.hitTokenCap = true
        val chat = ChatModel(engine)
        var cancelled = false
        var checksAfterStop = 0
        engine.onFirst = {
            chat.stopGenerating()
            cancelled = true
        }

        val result = chat.send("question", isCancelled = {
            if (cancelled) checksAfterStop++
            cancelled
        })

        assertEquals("partial", result)
        assertEquals(listOf("question", "partial"), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertEquals(0, checksAfterStop, "explicit Stop decides the turn without treating Job cancellation as abandonment")
        assertEquals(1, engine.cancellations)
        assertFalse(chat.isGenerating)
        assertFalse(chat.lastHitTokenCap)
        assertEquals("next reply", chat.send("next"))
        assertEquals(listOf("question", "partial", "next"), engine.secondHistory)
    }

    @Test fun externalCancellationDiscardsThePartialBeforeTheNextTurn() {
        val persistence = InMemoryConversationPersistence()
        val engine = StopEngine(listOf("part"))
        val chat = ChatModel(engine)
        val coordinator = ConversationCoordinator(chat, persistence, now = { 6L }, makeId = { "chat" })
        val id = coordinator.currentId!!
        engine.errorAfterHook = java.util.concurrent.CancellationException("external cancellation")

        assertFailsWith<java.util.concurrent.CancellationException> { chat.send("question") }

        assertFalse(chat.isGenerating)
        assertEquals(listOf("question"), chat.messages.map { it.text })
        assertEquals(listOf("question"), chat.completedMessages().map { it.text })

        assertEquals("next reply", chat.send("next"))
        assertEquals(listOf("question", "next"), engine.secondHistory)
        coordinator.persist()
        coordinator.open(id)

        assertEquals(listOf("question", "next", "next reply"), chat.messages.map { it.text })
        assertEquals(listOf("question", "next", "next reply"), persistence.loadTranscript(id).map { it.text })
    }

}
