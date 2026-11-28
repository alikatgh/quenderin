package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ChatTemplateTest {
    @Test fun jsonModeSendsTheSameStructuredTurnsToTheNativeTemplate() {
        val turns = listOf(ChatMessage(Role.USER, "first"), ChatMessage(Role.ASSISTANT, "reply"),
            ChatMessage(Role.USER, "next\u001Fquestion"))
        val grammar = JSONOutputGrammar.ANY_JSON_OBJECT
        val plain = LlamaEngine.prepareChatStream("system instructions", turns, ThinkingMode.SHOW, null)
        val json = LlamaEngine.prepareChatStream("system instructions", turns, ThinkingMode.SHOW, grammar)

        assertEquals("system\u001Fsystem instructions\u001Euser\u001Ffirst\u001Eassistant\u001Freply\u001Euser\u001Fnext question\u001E",
            plain.payload)
        assertEquals(plain.payload, json.payload)
        assertNull(plain.grammar)
        assertFalse(plain.disableThinking)
        assertEquals(grammar, json.grammar)
        assertTrue(json.disableThinking)
    }
}
