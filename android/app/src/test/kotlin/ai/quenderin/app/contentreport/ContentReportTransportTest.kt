package ai.quenderin.app.contentreport

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.TimeUnit

class ContentReportTransportTest {
    private val endpoint = "https://script.google.com/macros/s/synthetic-fixture/exec"
    private val redirect = "https://script.googleusercontent.com/macros/echo?synthetic=fixture"
    private val report = ContentReportProtocol.prepare(ReportDraft(ReportSource.REMOTE, "0.6.0", "Synthetic only.",
        reportId = "12345678-1234-4234-8234-123456789abc"))!!
    private val receipt = """{"ok":true,"code":"received","reportId":"${report.reportId}","receiptId":"87654321-4321-4321-8321-cba987654321","receivedAt":"2026-10-28T00:00:00.000Z"}"""

    @Test fun `one POST follows only ContentService redirect as GET without a body`() {
        val requests = mutableListOf<ReportHttpRequest>()
        val transport = ContentReportTransport(endpoint, ReportExchange {
            requests += it
            if (requests.size == 1) ReportHttpResponse(302, redirect) else ReportHttpResponse(200, body = receipt)
        })
        assertTrue(transport.send(report) is ReportResult.Received)
        assertEquals(2, requests.size)
        assertEquals(report.json, requests[0].body)
        assertEquals(endpoint, requests[0].url.toString())
        assertNull(requests[1].body)
        assertEquals(redirect, requests[1].url.toString())
        assertTrue(requests.all { it.remainingMillis in 1..20_000 })
    }

    @Test fun `302 and 303 are allowed but redirects never replay POST`() {
        for (status in listOf(302, 303)) {
            val requests = mutableListOf<ReportHttpRequest>()
            val transport = ContentReportTransport(endpoint, ReportExchange {
                requests += it
                if (requests.size == 1) ReportHttpResponse(status, redirect) else ReportHttpResponse(200, body = receipt)
            })
            assertTrue(transport.send(report) is ReportResult.Received)
            assertEquals(1, requests.count { it.body != null })
        }
    }

    @Test fun `absent unsafe or unversioned endpoints fail closed without HTTP`() {
        var requests = 0
        val invalid = listOf(null, "", "http://script.google.com/macros/s/id/exec", "https://script.google.com/macros/s/id/dev",
            "$endpoint?key=value", "$endpoint#fragment", "https://owner:password@script.google.com/macros/s/id/exec",
            "https://script.google.com.evil.example/macros/s/id/exec", "https://script.google.com:8443/macros/s/id/exec")
        invalid.forEach { url -> assertEquals(ReportResult.Unavailable, ContentReportTransport(url, ReportExchange {
            requests++; ReportHttpResponse(200, body = receipt)
        }).send(report)) }
        assertEquals(0, requests)
    }

    @Test fun `unknown insecure credentialed and fragment redirect locations are rejected`() {
        val locations = listOf("https://accounts.google.com/login", "https://script.google.com/macros/s/id/exec", "/relative",
            "https://script.googleusercontent.com.evil.example/receipt", "http://script.googleusercontent.com/receipt",
            "https://user:password@script.googleusercontent.com/receipt", "https://script.googleusercontent.com/receipt#fragment",
            "https://script.googleusercontent.com:8443/receipt")
        for (location in locations) {
            var requests = 0
            val result = ContentReportTransport(endpoint, ReportExchange { requests++; ReportHttpResponse(302, location) }).send(report)
            assertEquals(ReportResult.Unconfirmed, result)
            assertEquals(1, requests)
        }
    }

    @Test fun `replay redirects and HTTP errors are never automatically retried`() {
        for (status in listOf(301, 307, 308, 401, 403, 408, 421, 429, 500, 503)) {
            var requests = 0
            assertEquals(ReportResult.Unconfirmed, ContentReportTransport(endpoint, ReportExchange {
                requests++; ReportHttpResponse(status, redirect)
            }).send(report))
            assertEquals(1, requests)
        }
    }

    @Test fun `redirect count and aggregate deadline are bounded`() {
        var requests = 0
        assertEquals(ReportResult.Unconfirmed, ContentReportTransport(endpoint, ReportExchange {
            requests++; ReportHttpResponse(302, redirect)
        }).send(report))
        assertEquals(3, requests) // Original request plus at most two GETs.
        var time = 0L
        requests = 0
        val timed = ContentReportTransport(endpoint, ReportExchange {
            requests++; time += TimeUnit.SECONDS.toNanos(21); ReportHttpResponse(200, body = receipt)
        }, nanoTime = { time })
        assertEquals(ReportResult.Unconfirmed, timed.send(report))
        assertEquals(1, requests)
    }

    @Test fun `network ambiguity invalid receipt HTTP200 and oversized body never become success`() {
        var requests = 0
        val failing = ContentReportTransport(endpoint, ReportExchange { requests++; throw IOException("synthetic timeout") })
        assertEquals(ReportResult.Unconfirmed, failing.send(report))
        assertEquals(1, requests)
        for (body in listOf("<html>Sign in</html>", "{}", receipt + " ".repeat(8192)))
            assertEquals(ReportResult.Unconfirmed, ContentReportTransport(endpoint, ReportExchange { ReportHttpResponse(200, body = body) }).send(report))
    }

    @Test fun `manual retry sends exact payload and server receipt rejection remains truthful`() {
        val payloads = mutableListOf<String?>()
        val transport = ContentReportTransport(endpoint, ReportExchange {
            payloads += it.body
            if (payloads.size == 1) ReportHttpResponse(200, body = """{"ok":false,"code":"unavailable"}""")
            else ReportHttpResponse(200, body = receipt)
        })
        assertEquals(ReportResult.Rejected("unavailable"), transport.send(report))
        assertTrue(transport.send(report) is ReportResult.Received)
        assertEquals(listOf(report.json, report.json), payloads)
    }

    @Test fun `receipt URL requires exact host and clean HTTPS`() {
        assertTrue(ContentReportTransport.validReceiptUrl(redirect.toHttpUrl()))
        assertFalse(ContentReportTransport.validReceiptUrl("https://script.googleusercontent.com@evil.example/path".toHttpUrl()))
        assertFalse(ContentReportTransport.validReceiptUrl("http://script.googleusercontent.com/path".toHttpUrl()))
    }
}
