package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * Real Beam/Muse/Jais output filters driven through `ChatModel`: only the VISIBLE final channel may
 * settle. Each scripted engine feeds the wire through the shipped filter (emitting the filter's
 * output as tokens) and returns the filter's own `finalText(wire)`, so these also pin the
 * stream-first settlement rule against a realistic filtered backend.
 *
 * Covered: every chunk boundary (a split must not change the answer), a trailing visible tail with
 * no terminating control token, and a partial control fragment at the end (dropped by `finish`).
 */
class FilteredBackendSettlementTest {

    private class FilteredEngine(
        private val chunks: List<String>,
        private val reply: String,
        private val makeFilter: ((String) -> Unit) -> Filter,
    ) : InferenceEngine {
        interface Filter {
            fun accept(piece: String)
            fun finish()
        }

        override val loadedModelId: String? = "filtered"
        override fun load(model: ModelEntry, filePath: String) {}
        override fun unload() {}
        override fun complete(prompt: String): String = reply

        override fun completeChat(
            systemPrompt: String,
            history: List<ChatMessage>,
            onToken: (String) -> Unit,
        ): String {
            val filter = makeFilter(onToken)
            for (chunk in chunks) filter.accept(chunk)
            filter.finish()
            return reply
        }
    }

    private fun beamFilter(emit: (String) -> Unit) = object : FilteredEngine.Filter {
        private val filter = BeamOutputFilter(emit)
        override fun accept(piece: String) = filter.accept(piece)
        override fun finish() = filter.finish()
    }

    private fun museFilter(emit: (String) -> Unit) = object : FilteredEngine.Filter {
        private val filter = MuseOutputFilter(emit)
        override fun accept(piece: String) = filter.accept(piece)
        override fun finish() = filter.finish()
    }

    private fun jaisFilter(emit: (String) -> Unit) = object : FilteredEngine.Filter {
        private val filter = JaisOutputFilter(emit)
        override fun accept(piece: String) = filter.accept(piece)
        override fun finish() = filter.finish()
    }

    private fun settle(
        chunks: List<String>,
        wire: String,
        makeFilter: ((String) -> Unit) -> FilteredEngine.Filter,
        finalText: (String) -> String,
    ): ChatModel {
        val chat = ChatModel(FilteredEngine(chunks, finalText(wire), makeFilter))
        chat.send("question")
        return chat
    }

    private fun assertVisibleOnly(text: String, visible: String, privateText: String, split: Int) {
        assertEquals(visible, text, "split=$split")
        assertFalse(text.contains(privateText), "private channel leaked at split=$split")
        assertFalse(text.contains("<|"), "control token leaked at split=$split")
        assertFalse(text.contains("to="), "recipient header leaked at split=$split")
        assertFalse(text.contains("</ifm|"), "reasoning closer leaked at split=$split")
    }

    private val beamWire = "<|channel|>analysis<|message|>PRIVATE<|end|>" +
        "<|start|>assistant<|channel|>final<|message|>Hello 🌲<|return|>hidden"
    private val museWire = " to=self<|message|>secret chain<|eom|><|start|>assistant to=commentary<|message|>aside" +
        "<|eom|><|start|>assistant to=user<|message|>Final answer.<|eot|>trailing hidden"
    private val jaisWire = "private reasoning</ifm|think>مرحباً world<|ifm|im_end|>hidden next turn"

    @Test fun beamSettlesOnlyTheFinalChannelAcrossEveryChunkBoundary() {
        for (split in 0..beamWire.length) {
            val chat = settle(
                listOf(beamWire.take(split), beamWire.drop(split)),
                beamWire,
                ::beamFilter,
                { BeamOutputFilter.finalText(it) },
            )
            assertVisibleOnly(chat.messages.last().text, "Hello 🌲", "PRIVATE", split)
        }
    }

    @Test fun museSettlesOnlyTheUserChannelAcrossEveryChunkBoundary() {
        for (split in 0..museWire.length) {
            val chat = settle(
                listOf(museWire.take(split), museWire.drop(split)),
                museWire,
                ::museFilter,
                { MuseOutputFilter.finalText(it) },
            )
            assertVisibleOnly(chat.messages.last().text, "Final answer.", "secret chain", split)
        }
    }

    @Test fun jaisSettlesOnlyTextAfterPrivateReasoningAcrossEveryChunkBoundary() {
        for (split in 0..jaisWire.length) {
            val chat = settle(
                listOf(jaisWire.take(split), jaisWire.drop(split)),
                jaisWire,
                ::jaisFilter,
                { JaisOutputFilter.finalText(it) },
            )
            assertVisibleOnly(chat.messages.last().text, "مرحباً world", "private reasoning", split)
        }
    }

    @Test fun trailingVisibleTailSurvivesWithoutATerminatingControl() {
        // Beams/Muse/Jais all emit the visible body before the terminator; `finish()` must keep it.
        val cases = listOf(
            Triple("<|channel|>final<|message|>Tail without terminator", "Tail without terminator", ::beamFilter),
            Triple(" to=user<|message|>Tail without terminator", "Tail without terminator", ::museFilter),
            Triple("private</ifm|think>Tail without terminator", "Tail without terminator", ::jaisFilter),
        )
        for ((wire, expected, factory) in cases) {
            val chat = settle(listOf(wire), wire, factory, { expected })
            assertEquals(expected, chat.messages.last().text, "wire=$wire")
        }
    }

    @Test fun partialControlTailNeverLeaksOnFinish() {
        // The visible body streams; the trailing fragment is held and dropped by finish().
        assertEquals("Hello", BeamOutputFilter.finalText("<|channel|>final<|message|>Hello<|ret"))
        assertEquals("Answer", MuseOutputFilter.finalText(" to=user<|message|>Answer<|eo"))
        assertEquals("answer", JaisOutputFilter.finalText("private</ifm|think>answer<|ifm|im_"))

        val beam = settle(
            listOf("<|channel|>final<|message|>Hello<|ret"),
            "<|channel|>final<|message|>Hello<|ret",
            ::beamFilter,
            { BeamOutputFilter.finalText(it) },
        )
        assertEquals("Hello", beam.messages.last().text)
    }

    @Test fun privateOnlyWireSettlesToTheHonestNotice() {
        val wire = "<|channel|>analysis<|message|>only private reasoning<|end|>"
        val chat = settle(listOf(wire), wire, ::beamFilter, { BeamOutputFilter.finalText(it) })

        assertEquals(ChatUserFacing.emptyReply(java.util.Locale.getDefault().language), chat.messages.last().text)
    }
}
