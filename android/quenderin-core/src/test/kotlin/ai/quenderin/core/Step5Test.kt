package ai.quenderin.core

import java.io.ByteArrayInputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue

class Step5Test {
    private val handshake = "{\"protocol\":1,\"modelRevision\":\"${Step5Contract.MODEL_REVISION}\",\"backendRevision\":\"${Step5Contract.BACKEND_REVISION}\",\"artifactsVerified\":true,\"ready\":true,\"maxOutputTokens\":1024,\"maxConcurrentRequests\":1}"
    @Test fun endpointAndStrictProtocolBounds() {
        for (endpoint in listOf("http://127.0.0.1:18000", "http://[::1]:18000", "https://cuda.example")) Step5Contract.endpoint(endpoint)
        for (endpoint in listOf("http://localhost:18000", "http://192.168.1.2", "https://user:pass@host", "https://host/path", "https://host/?token=x", "https://host/#x", "file:///private/tmp/model")) assertFails { Step5Contract.endpoint(endpoint) }
        Step5Contract.handshake(handshake.toByteArray())
        assertFails { Step5Contract.handshake(handshake.replace("\"ready\":true", "\"ready\":false").toByteArray()) }
        for (output in listOf("{\"text\":\"x\",\"text\":\"y\",\"truncated\":false}", "{\"text\":\"x\",\"truncated\":false} trailing", "{\"text\":{},\"truncated\":false}", "{\"text\":\"<think>private</think>\",\"truncated\":false}")) assertFails { Step5Contract.answer(output.toByteArray()) }
    }
    @Test fun actualClientHandshakeAndAnswerUseFixedRoutesAndBoundResponses() {
        val routes = mutableListOf<String>()
        val transport = object : Step5Transport {
            override fun open(url: java.net.URI, body: ByteArray?, timeoutMs: Int): Step5Response {
                routes += url.path
                val bytes = (if (url.path == "/quenderin/step5") handshake else "{\"text\":\"Fixture final answer\",\"truncated\":false}").toByteArray()
                return Step5Response(200, bytes.size.toLong(), ByteArrayInputStream(bytes)) {}
            }
            override fun cancel() {}
        }
        val client = Step5Client({ transport })
        assertEquals("Fixture final answer", client.answer("https://fixture.invalid", listOf(Step5Message("user", "Test fixture prompt"))).text)
        assertEquals(listOf("/quenderin/step5", "/quenderin/step5/answer"), routes)
    }
    @Test fun unknownLengthOverflowAndPrivateOutputAreRejectedAndClosed() {
        for (output in listOf(ByteArray(300 * 1024 + 1) { 65 }, "{\"text\":\"<think>fixture private</think>\",\"truncated\":false}".toByteArray())) {
            var closed = 0
            val transport = object : Step5Transport {
                override fun open(url: java.net.URI, body: ByteArray?, timeoutMs: Int): Step5Response {
                    val bytes = if (body == null) handshake.toByteArray() else output
                    return Step5Response(200, -1, ByteArrayInputStream(bytes)) { closed++ }
                }
                override fun cancel() {}
            }
            assertFails { Step5Client({ transport }).answer("https://fixture.invalid", listOf(Step5Message("user", "Test fixture prompt"))) }
            assertEquals(2, closed)
        }
    }
    @Test fun watchdogCancelsBlockedTransportAndConcurrentRequestIsRejected() {
        val opened = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val transport = object : Step5Transport {
            override fun open(url: java.net.URI, body: ByteArray?, timeoutMs: Int): Step5Response {
                opened.countDown()
                check(cancelled.await(2, TimeUnit.SECONDS)) { "Fixture was not cancelled." }
                throw java.util.concurrent.CancellationException("Fixture cancelled.")
            }
            override fun cancel() { cancelled.countDown() }
        }
        val client = Step5Client({ transport }, 100)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val pending = executor.submit<Boolean> { runCatching { client.check("https://fixture.invalid") }.isFailure }
            assertTrue(opened.await(1, TimeUnit.SECONDS))
            assertFails { client.check("https://fixture.invalid") }
            assertTrue(pending.get(2, TimeUnit.SECONDS))
            assertEquals(0L, cancelled.count)
        } finally { client.cancel(); executor.shutdownNow() }
        val cancelledBeforeOpen = Step5JvmHttpTransport().apply { cancel() }
        assertFails { cancelledBeforeOpen.open(java.net.URI("https://fixture.invalid"), null, 1) }
    }
}
