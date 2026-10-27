package ai.quenderin.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class MaxModelBindingTest {
    private val receipt = MaxModelReceipt(
        files = listOf(MaxModelFile("/tmp/model.mef", 8, "a".repeat(64))),
        runnerName = "synthetic-runner", backend = "cpu", contextTokens = 16, maxOutputTokens = 4,
    )

    private class FakeApi : MaxModelApi {
        var generatedRun = 0L
        var generatedPrompt = ""
        var cancelRun = 0L
        var closeCode = MaxModelCode.OK
        var generateCode = MaxModelCode.OK
        var generateCalls = 0
        var cancelCalls = 0

        override fun verify(receipt: MaxModelReceipt) = MaxVerification(MaxModelCode.OK, "")
        override fun capability(receipt: MaxModelReceipt, loadProbePassed: Boolean) =
            MaxModelCapability(MaxModelCode.OK, true, loadProbePassed, loadProbePassed, "synthetic-runner",
                "cpu", "", 16, 4)
        override fun open(receipt: MaxModelReceipt) =
            MaxOpenResult.Unavailable(MaxModelCode.UNAVAILABLE, "not used")
        override fun generate(handle: Long, runId: Long, prompt: String, maxTokens: Int, temperature: Float,
                              topP: Float, seed: Int, sink: MaxTokenSink): MaxGenerationResult {
            generatedRun = runId
            generateCalls += 1
            generatedPrompt = prompt
            sink.onToken("ok")
            return MaxGenerationResult(generateCode,
                MaxGenerationPerformance(1, 1, 1.0, 1.0, 1.0, 0.0,
                    if (generateCode == MaxModelCode.OK) MaxModelStatus.COMPLETE else MaxModelStatus.CANCELLED, 0), null)
        }
        override fun cancel(handle: Long, runId: Long): Boolean {
            cancelRun = runId
            cancelCalls += 1
            return true
        }
        override fun close(handle: Long): Int = closeCode
    }

    @Test fun generationAssignsARunAndCancelsOnlyWhileActive() {
        val api = FakeApi()
        val handle = MaxModelHandle(7, receipt, api)
        assertFalse(handle.cancel(), "idle cancel must be a no-op")
        val text = StringBuilder()
        assertTrue(handle.generate("hi") { text.append(it); true }.succeeded)
        assertEquals("ok", text.toString())
        assertEquals(1L, api.generatedRun)
        assertFalse(handle.cancel(), "completed run must not accept a stale cancel")
    }

    @Test fun explicitRunTokenReachesTheBridge() {
        val api = FakeApi()
        val handle = MaxModelHandle(10, receipt, api)
        val token = handle.newRunToken()
        assertTrue(handle.generate("hi", token = token) { true }.succeeded)
        assertEquals(token.id, api.generatedRun)
    }

    @Test fun pendingCancellationSurvivesCompletedAndUnrelatedTokens() {
        val api = FakeApi()
        val handle = MaxModelHandle(10, receipt, api)
        val completed = handle.newRunToken()
        assertTrue(handle.generate("hi", token = completed) { true }.succeeded)
        val pending = handle.newRunToken()
        val otherPending = handle.newRunToken()
        assertTrue(handle.cancel(pending))
        assertFalse(handle.cancel(completed))
        assertTrue(handle.cancel(otherPending))
        assertEquals(MaxModelCode.CANCELLED, handle.generate("hi", token = otherPending) { true }.code)
        assertEquals(MaxModelCode.CANCELLED, handle.generate("hi", token = pending) { true }.code)
        assertEquals(1, api.generateCalls, "pending cancellations must not reach the native runner")
        assertEquals(0, api.cancelCalls, "completed/pending tokens need no model-wide native cancel")
        assertFalse(handle.cancel(pending))
        assertFalse(handle.cancel(completed))
        assertFailsWith<IllegalArgumentException> { handle.generate("hi", token = completed) { true } }
        assertTrue(handle.generate("hi") { true }.succeeded)
    }

    @Test fun foreignTokenCannotCancelOrGenerate() {
        val api = FakeApi()
        val first = MaxModelHandle(10, receipt, api)
        val second = MaxModelHandle(11, receipt, api)
        val token = first.newRunToken()
        assertFalse(second.cancel(token))
        assertFailsWith<IllegalArgumentException> { second.generate("hi", token = token) { true } }
        assertTrue(first.generate("hi", token = token) { true }.succeeded)
        assertEquals(0, api.cancelCalls)
    }

    @Test fun closeRefusesBusyThenClosesOnce() {
        val api = FakeApi()
        val handle = MaxModelHandle(8, receipt, api)
        api.closeCode = MaxModelCode.BUSY
        assertEquals(MaxCloseResult.BUSY, handle.close())
        assertFalse(handle.isClosed)
        api.closeCode = MaxModelCode.OK
        assertEquals(MaxCloseResult.CLOSED, handle.close())
        assertTrue(handle.isClosed)
        assertEquals(MaxCloseResult.CLOSED, handle.close())
        assertFailsWith<IllegalStateException> { handle.generate("hi") { true } }
    }

    @Test fun invalidRequestsFailBeforeTheBridge() {
        val api = FakeApi()
        val handle = MaxModelHandle(9, receipt, api)
        assertFailsWith<IllegalArgumentException> { handle.generate("") { true } }
        assertFailsWith<IllegalArgumentException> { handle.generate("hi", maxTokens = 5) { true } }
        assertFailsWith<IllegalArgumentException> { handle.generate("hi", topP = 0f) { true } }
        assertEquals(0L, api.generatedRun)
    }

    @Test fun receiptRejectsUnsafeOrUnpinnedInputs() {
        assertFailsWith<IllegalArgumentException> {
            MaxModelReceipt(listOf(MaxModelFile("relative.mef", 1, "a".repeat(64))),
                "runner", "cpu", 16, 4)
        }
        assertFailsWith<IllegalArgumentException> {
            MaxModelReceipt(listOf(MaxModelFile("/tmp/model.mef", 1, "A".repeat(64))),
                "runner", "cpu", 16, 4)
        }
        assertFailsWith<IllegalArgumentException> {
            MaxModelReceipt(listOf(
                MaxModelFile("/tmp/a.mef", MaxModelLimits.MAX_FILE_BYTES, "a".repeat(64)),
                MaxModelFile("/tmp/b.mef", MaxModelLimits.MAX_FILE_BYTES, "b".repeat(64)),
            ), "runner", "cpu", 16, 4)
        }
    }

    @Test fun receiptSnapshotsTheCallerList() {
        val files = mutableListOf(MaxModelFile("/tmp/model.mef", 8, "a".repeat(64)))
        val receipt = MaxModelReceipt(files, "synthetic-runner", "cpu", 16, 4)
        files[0] = files[0].copy(sha256 = "")
        assertEquals(64, receipt.files[0].sha256.length)
        assertEquals("a".repeat(64), receipt.files[0].sha256)
    }

    @Test fun performanceMappingIsBoundedAndFinite() {
        val values = doubleArrayOf(2.0, 6.0, Double.NaN, -1.0, 0.0, Double.POSITIVE_INFINITY, 3.0, 1.0)
        val performance = MaxGenerationPerformance.from(values)
        assertEquals(2, performance.promptTokens)
        assertEquals(6, performance.decodedTokens)
        assertEquals(0.0, performance.prefillMs)
        assertEquals(0.0, performance.decodeMs)
        assertEquals(0.0, performance.maxGapMs)
        assertEquals(3, performance.status)
        assertEquals(1, performance.cacheMode)
    }
}
