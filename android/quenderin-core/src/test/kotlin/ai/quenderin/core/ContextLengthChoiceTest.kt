package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals

class ContextLengthChoiceTest {
    @Test fun manualContextClampsBelowTwoThousandTokensWhenNeeded() {
        val resolved = ContextWindow.resolve(ContextLengthChoice.K2, 2.0, 1.5, KVCacheType.F16)
        assertEquals(512, resolved.tokens)
        assertEquals("Not enough memory on this device for this length; using 512 tokens.", resolved.warningText)
    }

    @Test fun f16RetryCannotAllocateWhenOnlyQuantizedMinimumFits() {
        val choice = ContextLengthChoice.K2
        assertEquals(256, ContextWindow.resolveForLoad(choice, 1.82, 1.5, KVCacheType.Q8_0))
        assertEquals(0, ContextWindow.resolveForLoad(choice, 1.82, 1.5, KVCacheType.F16))
        val f16 = ContextWindow.resolve(choice, 1.82, 1.5, KVCacheType.F16)
        assertEquals("Not enough memory for a context window at this setting.", f16.warningText)
    }
}
