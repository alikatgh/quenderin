package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Chat-settlement parity with iOS `ChatModel`:
 *
 * - the transcript settles from the STREAMED pieces; the engine return is only the
 *   non-streaming fallback (an engine that emits A and returns B settles A);
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
        private val reportsCap: Boolean = false,
    ) : InferenceEngine {
        var cancelCount = 0
        var delivered = 0
        override val loadedModelId: String? = "scripted"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = reply
        override fun requestCancel() { cancelCount++ }
        override fun lastHitTokenCap(): Boolean = reportsCap
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

    @Test fun noEmissionFallsBackToEngineReturn() {
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
        val engine = ScriptedEngine(all, reply = all.joinToString(""), reportsCap = true)
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
