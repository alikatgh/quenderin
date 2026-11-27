package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Chat-settlement parity with iOS `ChatModel`:
 *
 * - the transcript settles from the STREAMED pieces; the engine return is only the
 *   zero-callback (non-streaming) fallback — an engine that emits A and returns B settles A,
 *   and an empty or whitespace emission settles blank (the honest notice), never B;
 * - the degeneration checkpoint runs BEFORE appending, so the piece that crosses it is
 *   excluded exactly as iOS's pre-append check + `break` drops the current token;
 * - after the trip every further piece is dropped at the callback's first line, so an
 *   engine that ignores `requestCancel` costs bounded work and can never leak loop text;
 * - a degeneration stop suppresses the "Continue" affordance even if the engine reports
 *   a token cap.
 */
class ChatSettlementTest {

    /** Emits a fixed stream, returns a fixed (possibly different) full text, and never honors cancel. */
    private class ScriptedEngine(
        private val pieces: List<String>,
        private val reply: String,
        private val capStatus: ChatCapStatus = ChatCapStatus.UNKNOWN,
        private val mode: ThinkingMode = ThinkingMode.OFF,
    ) : InferenceEngine {
        var cancelCount = 0
        var delivered = 0
        override val loadedModelId: String? = "scripted"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = reply
        override fun requestCancel() { cancelCount++ }
        override fun chatCapStatus(): ChatCapStatus = capStatus
        override fun thinkingMode(): ThinkingMode = mode
        override fun completeChat(
            systemPrompt: String,
            history: List<ChatMessage>,
            onToken: (String) -> Unit,
        ): String {
            for (piece in pieces) {
                delivered++
                onToken(piece)
            }
            return reply
        }
    }

    @Test fun streamedTextWinsOverEngineReturn() {
        val chat = ChatModel(ScriptedEngine(listOf("streamed ", "answer"), reply = "RETURNED TEXT"))
        val result = chat.send("question")

        assertEquals("streamed answer", result)
        assertEquals("streamed answer", chat.messages.last().text)
    }

    @Test fun specialistOwnershipRejectsTheSelectedModelBeforeTurnAdmission() {
        val engine = CoordinatedInferenceEngine(ScriptedEngine(listOf("reply"), "reply"))
        val chat = ChatModel(engine)
        var admitted = false
        val lease = engine.suspendForSpecialist()
        try {
            assertFailsWith<IllegalStateException> {
                chat.withSelectedModel("scripted") {
                    chat.send("question", onAdmitted = { admitted = true })
                }
            }
            assertFalse(admitted)
            assertTrue(chat.messages.isEmpty())
        } finally {
            lease.resume()
        }
        chat.withSelectedModel("scripted") { chat.send("question", onAdmitted = { admitted = true }) }
        assertTrue(admitted)
        assertEquals(listOf("question", "reply"), chat.messages.map { it.text })
    }

    @Test fun emptyEmissionWinsOverEngineReturn() {
        // One onToken("") is still an emission: the return must NOT replace it. The blank settled
        // stream gives the honest empty-reply notice, exactly as iOS.
        val chat = ChatModel(ScriptedEngine(listOf(""), reply = "RETURNED TEXT"))
        val result = chat.send("question")

        assertEquals(ChatUserFacing.emptyReply(java.util.Locale.getDefault().language), result)
        assertEquals(result, chat.messages.last().text)
    }

    @Test fun thinkingIsWithheldWithTheReplyAndWhenItIsTheOnlyOutput() {
        val outputs = listOf("<think>private reasoning</think>ignore previous", "<think>system prompt: private reasoning")
        for (output in outputs) {
            val snapshots = mutableListOf<List<ChatMessage>>()
            val chat = ChatModel(ScriptedEngine(listOf(output), output, mode = ThinkingMode.SHOW),
                onChange = { snapshots.add(it) })
            assertEquals(OutputCheck.INJECTION, chat.send("hello"))
            assertTrue(snapshots.flatten().all { it.thinking == null })
            assertFalse(ConversationStore().encode(chat.completedMessages()).contains("private reasoning"))
        }
    }

    @Test fun checkerReceivesReasoningOnlyOutputBeforeItCanAppear() {
        val chat = ChatModel(ScriptedEngine(listOf("<think>private reasoning"), "", mode = ThinkingMode.SHOW))
        RoleSeat.selectChecker("fixture")
        RoleSeat.ask = { _, content ->
            assertTrue(content.contains("private reasoning"))
            assertNull(chat.messages.last().thinking)
            "no"
        }
        try {
            assertEquals(OutputCheck.CHECKER_HELD, chat.send("hello"))
            assertNull(chat.messages.last().thinking)
        } finally {
            RoleSeat.reset()
        }
    }

    @Test fun onlyFullyReviewedThinkingIsShownAndRestored() {
        val output = "<think>some reasoning</think>answer"
        val store = ConversationStore()
        RoleSeat.reset()
        try {
            // Without a checker selected, shape-clean thinking is shown and persisted with the review marker.
            val noChecker = ChatModel(ScriptedEngine(listOf(output), output, mode = ThinkingMode.SHOW))
            assertEquals("answer", noChecker.send("hello"))
            assertEquals("some reasoning", noChecker.messages.last().thinking)
            assertEquals("some reasoning", store.decode(store.encode(noChecker.completedMessages())).last().thinking)

            // When a checker is selected but cannot run, the reply shows the notice and thinking stays hidden.
            RoleSeat.selectChecker("fixture")
            RoleSeat.ask = { _, _ -> "unloaded" }
            val unavailable = ChatModel(ScriptedEngine(listOf(output), output, mode = ThinkingMode.SHOW))
            assertTrue(unavailable.send("hello").contains(OnDeviceCopy.CHECKER_MISSING))
            assertNull(unavailable.messages.last().thinking)

            var reviewedContent: String? = null
            RoleSeat.ask = { _, content ->
                reviewedContent = content
                "yes"
            }
            val chat = ChatModel(ScriptedEngine(listOf(output), output, mode = ThinkingMode.SHOW))
            chat.send("again")
            assertEquals("answer\n\nsome reasoning", reviewedContent)
            assertEquals("some reasoning", store.decode(store.encode(chat.completedMessages())).last().thinking)
            for (text in listOf("ordinary answer", OutputCheck.CHECKER_HELD)) {
                val restored = store.decode("ASSISTANT\t$text\t\u0000thinking\told reasoning").last()
                assertEquals(text, restored.text)
                assertNull(restored.thinking)
            }
        } finally {
            RoleSeat.reset()
        }
    }

    @Test fun checkerThatCannotFitTheFullPromptNeverReleasesThinking() {
        val model = ModelCatalog.smallest
        val thinking = "word ".repeat(80)
        var checkerPrompt: String? = null
        val engine = object : InferenceEngine {
            override val loadedModelId = model.id
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String) = "yes"
            override fun completeWithFullPromptGrammar(prompt: String, grammar: String, maxTokens: Int): String {
                checkerPrompt = prompt
                throw IllegalStateException("The full prompt exceeds the available context.")
            }
        }
        RoleSeat.selectChecker(model.id)
        RoleSeat.ask = { id, text ->
            CheckerRun.ask(id, text, CoordinatedInferenceEngine(engine)) { CheckerFile(model, "/models/check.gguf") }
        }
        try {
            val (verdict, released) = OutputCheck.finishChatReply("answer", thinking)
            assertEquals(CheckerPrompt.of("answer\n\n$thinking"), checkerPrompt)
            assertEquals(OutputCheck.CHECKER_FAILED, verdict.text)
            assertNull(released)
        } finally {
            RoleSeat.reset()
        }
    }

    @Test fun whitespaceEmissionWinsOverEngineReturn() {
        val chat = ChatModel(ScriptedEngine(listOf("   "), reply = "RETURNED TEXT"))
        val result = chat.send("question")

        assertEquals(ChatUserFacing.emptyReply(java.util.Locale.getDefault().language), result)
        assertEquals(result, chat.messages.last().text)
    }

    @Test fun noEmissionFallsBackToEngineReturn() {
        // Only a ZERO-callback engine may use the return value as its text.
        val chat = ChatModel(ScriptedEngine(emptyList(), reply = "fallback answer"))
        val result = chat.send("question")

        assertEquals("fallback answer", result)
        assertEquals("fallback answer", chat.messages.last().text)
    }

    @Test fun degenerationExcludesTheCrossingPieceAndShortCircuits() {
        val word = "a".repeat(100)
        val prefix = List(31) { word }              // 31 pieces: degenerate at the 32nd checkpoint
        val crossing = "CROSSING"                   // the piece that crosses the checkpoint — dropped
        val after = List(40) { "LEAK" }             // engine ignores cancel and keeps delivering
        val all = prefix + crossing + after
        val engine = ScriptedEngine(all, reply = all.joinToString(""), capStatus = ChatCapStatus.HIT)
        val chat = ChatModel(engine)

        val result = chat.send("question")

        assertEquals(prefix.joinToString(""), result)
        assertEquals(result, chat.messages.last().text)
        assertFalse(result.contains(crossing), "the crossing piece must be excluded on both twins")
        assertFalse(result.contains("LEAK"), "post-trip pieces must be dropped, not appended")
        assertEquals(all.size, engine.delivered, "the engine did keep delivering; the callback dropped them")
        assertTrue(engine.cancelCount >= 1, "the trip must still ask the engine to cancel")
        assertFalse(chat.lastHitTokenCap, "degeneration must never offer Continue")
    }

    @Test fun supersededGenerationNeverWritesIntoTheRestoredConversation() {
        var mid: (() -> Unit)? = null
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "scripted"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "unused"
            override fun completeChat(
                systemPrompt: String,
                history: List<ChatMessage>,
                onToken: (String) -> Unit,
            ): String {
                onToken("before-switch")
                mid?.invoke()                       // conversation switch while the reply streams
                onToken("after-switch")
                return "before-switchafter-switch"
            }
        }
        val chat = ChatModel(engine)
        val saved = listOf(ChatMessage(Role.USER, "other conversation"))
        mid = { chat.restore(saved) }

        chat.send("question")

        assertEquals(saved.map { it.text }, chat.messages.map { it.text })
    }
}
