package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue
import java.nio.file.Files

class HyMemoryTest {
    @Test fun strictGrammarAndOfficialNoThinkFraming() {
        assertEquals(listOf("Tea"), HyMemory.parse("{\"memories\":[\"Tea\"]}"))
        for (invalid in listOf("{\"memories\":[],\"memories\":[\"x\"]}", "{\"memories\":[],\"extra\":1}", "{\"memories\":[1]}", "{\"memories\":[\"\"]}", "{\"memories\":[]} trailing", "<think>private</think>{\"memories\":[]}")) assertFails { HyMemory.parse(invalid) }
        val prompt = HyMemory.prompt("User: I prefer tea.")
        assertTrue(prompt.startsWith("<｜hy_begin▁of▁sentence｜>")); assertTrue(prompt.endsWith("<｜hy_Assistant｜><think></think>"))
        assertTrue(prompt.contains("<｜reasoning_mode｜>reasoning_effort:no_think<｜hy_User｜>"))
        assertFails { HyMemory.prompt("é".repeat(4097)) }
    }
    @Test fun explicitStoreIsIdempotentAndDoesNotTouchOtherData() {
        val directory = Files.createTempDirectory("quenderin-hy-fixture-").toFile()
        try {
            val store = HyApprovedMemoryStore(directory); val selected = HyMemoryProposal(text = "Test fixture preference")
            assertEquals(0, directory.list()!!.size); store.save(selected); store.save(selected)
            assertEquals(1, directory.list()!!.size)
        } finally { directory.deleteRecursively() }
    }
}
