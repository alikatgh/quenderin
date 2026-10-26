package ai.quenderin.core

import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Consumer contract: only an observed budget stop offers Continue, irrespective of piece count. */
class ChatCapSettlementTest {
    private data class Outcome(val pieces: List<String>, val status: ChatCapStatus)

    private class StatusEngine(
        private val outcomes: List<Outcome>,
        private val gateFirstStatus: Boolean = false,
    ) : InferenceEngine {
        val statusEntered = CountDownLatch(1)
        val releaseStatus = CountDownLatch(1)
        var calls = 0
        var requestedBudget = 0
        var lastHistory: List<ChatMessage> = emptyList()
        override val loadedModelId = "cap-settlement"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = error("structured completion expected")
        override fun setChatTokenBudget(tokens: Int) { requestedBudget = tokens }
        override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
            lastHistory = history
            val outcome = outcomes[calls++]
            outcome.pieces.forEach(onToken)
            return outcome.pieces.joinToString("")
        }
        override fun chatCapStatus(): ChatCapStatus {
            // Capture the result before yielding: a later turn must not change this stale read.
            val call = calls
            val status = outcomes[call - 1].status
            if (gateFirstStatus && call == 1) {
                statusEntered.countDown()
                check(releaseStatus.await(5, TimeUnit.SECONDS)) { "cap status gate timed out" }
            }
            return status
        }
    }

    private fun withBlockedStatus(
        engine: StatusEngine,
        chat: ChatModel,
        isCancelled: () -> Boolean = { false },
        action: () -> Unit,
    ): Throwable? {
        val failure = AtomicReference<Throwable?>()
        val worker = thread(isDaemon = true, name = "chat-cap-settlement") {
            try { chat.send("question", isCancelled = isCancelled) } catch (t: Throwable) { failure.set(t) }
        }
        try {
            assertTrue(engine.statusEntered.await(5, TimeUnit.SECONDS), "status read reached")
            action()
        } finally {
            engine.releaseStatus.countDown()
            worker.join(5_000)
        }
        assertFalse(worker.isAlive, "send settled after releasing status")
        return failure.get()
    }

    @Test fun hitWithZeroOrFewPiecesOffersContinueAndPreservesEmptyReplyNotice() {
        for (pieces in listOf(emptyList(), listOf("short answer"))) {
            val chat = ChatModel(StatusEngine(listOf(Outcome(pieces, ChatCapStatus.HIT))))
            val expected = pieces.firstOrNull() ?: ChatUserFacing.emptyReply(java.util.Locale.getDefault().language)
            assertEquals(expected, chat.send("question"))
            assertEquals(expected, chat.messages.last().text)
            assertTrue(chat.lastHitTokenCap)
        }
    }

    @Test fun manyPiecesNeverSubstituteForNotHitOrUnknown() {
        val pieces = (0 until 1024).map { "piece-$it;" }
        for (status in listOf(ChatCapStatus.NOT_HIT, ChatCapStatus.UNKNOWN)) {
            val engine = StatusEngine(listOf(Outcome(pieces, status)))
            val chat = ChatModel(engine)
            assertEquals(pieces.joinToString(""), chat.send("question"))
            assertTrue(pieces.size > engine.requestedBudget)
            assertFalse(chat.lastHitTokenCap)
        }
    }

    @Test fun successiveStatusesReplaceThePreviousOutcome() {
        val statuses = listOf(ChatCapStatus.HIT, ChatCapStatus.UNKNOWN, ChatCapStatus.HIT, ChatCapStatus.NOT_HIT)
        val chat = ChatModel(StatusEngine(statuses.map { Outcome(listOf("answer"), it) }))
        for (status in statuses) {
            chat.send("question")
            assertEquals(status == ChatCapStatus.HIT, chat.lastHitTokenCap)
        }
    }

    @Test fun stopDuringStatusRetainsAcceptedTextAndSuppressesHit() {
        val engine = StatusEngine(listOf(Outcome(listOf("accepted"), ChatCapStatus.HIT)), true)
        val chat = ChatModel(engine)
        assertNull(withBlockedStatus(engine, chat) { chat.stopGenerating() })
        assertEquals(listOf("question", "accepted"), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.completedMessages())
        assertEquals(chat.messages, chat.persistSnapshot().first)
        assertFalse(chat.lastHitTokenCap)
    }

    @Test fun navigationDuringStatusCannotOverwriteRestoredSameId() {
        val engine = StatusEngine(listOf(Outcome(listOf("partial"), ChatCapStatus.HIT)), true)
        val chat = ChatModel(engine)
        var restored: List<ChatMessage> = emptyList()
        var revision = 0L
        assertNull(withBlockedStatus(engine, chat) {
            restored = listOf(chat.messages.last().copy(text = "saved answer"))
            chat.restore(restored)
            revision = chat.persistSnapshot().second
        })
        assertEquals(restored, chat.messages)
        assertEquals(restored, chat.completedMessages())
        assertEquals(revision, chat.persistSnapshot().second)
        assertFalse(chat.lastHitTokenCap)
    }

    @Test fun staleStatusCannotChangeTheNextSettledTurnsOutcome() {
        for ((stale, fresh) in listOf(ChatCapStatus.HIT to ChatCapStatus.NOT_HIT, ChatCapStatus.NOT_HIT to ChatCapStatus.HIT)) {
            val engine = StatusEngine(listOf(Outcome(listOf("old"), stale), Outcome(listOf("new"), fresh)), true)
            val chat = ChatModel(engine)
            assertNull(withBlockedStatus(engine, chat) {
                chat.reset()
                assertEquals("new", chat.send("next"))
            })
            assertEquals(listOf("next", "new"), chat.messages.map { it.text })
            assertEquals(fresh == ChatCapStatus.HIT, chat.lastHitTokenCap)
        }
    }

    @Test fun cancellationDuringStatusDiscardsPartialAndDoesNotLeakIntoNextHistory() {
        val cancelled = AtomicBoolean(false)
        val engine = StatusEngine(listOf(Outcome(listOf("partial"), ChatCapStatus.HIT), Outcome(listOf("new"), ChatCapStatus.UNKNOWN)), true)
        val chat = ChatModel(engine)
        val failure = withBlockedStatus(engine, chat, cancelled::get) { cancelled.set(true) }
        assertTrue(failure is CancellationException)
        assertEquals(listOf("question"), chat.messages.map { it.text })
        assertEquals(chat.messages, chat.persistSnapshot().first)
        assertFalse(chat.lastHitTokenCap)
        chat.send("next")
        assertFalse(engine.lastHistory.any { it.text == "partial" })
        assertFalse(chat.lastHitTokenCap)
    }

    @Test fun degenerationSuppressesAnObservedHit() {
        val pieces = List(40) { "abcdefghijklmnop" }
        val chat = ChatModel(StatusEngine(listOf(Outcome(pieces, ChatCapStatus.HIT))))
        chat.send("question")
        assertEquals(pieces.take(31).joinToString(""), chat.messages.last().text)
        assertFalse(chat.lastHitTokenCap)
    }
}
