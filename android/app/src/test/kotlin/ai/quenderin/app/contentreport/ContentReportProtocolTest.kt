package ai.quenderin.app.contentreport

import org.junit.Assert.*
import org.junit.Test

class ContentReportProtocolTest {
    private val id = "12345678-1234-4234-8234-123456789abc"
    private val receipt = "87654321-4321-4321-8321-cba987654321"
    private fun draft(content: String = "Synthetic fixture excerpt.") =
        ReportDraft(ReportSource.LOCAL_CHAT, "0.6.0", content, reportId = id)
    private fun response(reportId: String = id, receiptId: String = receipt, time: String = "2026-10-28T00:00:00.000Z") =
        """{"ok":true,"code":"received","reportId":"$reportId","receiptId":"$receiptId","receivedAt":"$time"}"""

    @Test fun `request contains only approved single excerpt fields and preserves exact text`() {
        val report = ContentReportProtocol.prepare(draft("A \"quote\"\n界 😀").copy(note = "Optional\ttext"))!!
        assertEquals(id, report.reportId)
        assertEquals("""{"schema":1,"reportId":"12345678-1234-4234-8234-123456789abc","platform":"android","appVersion":"0.6.0","source":"local-chat","reason":"other","content":"A \"quote\"\n界 😀","note":"Optional\ttext"}""", report.json)
    }

    @Test fun `every supported source and reason prepares without invented fields`() {
        for (source in ReportSource.entries) for (reason in ReportReason.entries) {
            val json = ContentReportProtocol.prepare(draft().copy(source = source, reason = reason))!!.json
            assertTrue(json.contains("\"source\":\"${source.wire}\""))
            assertTrue(json.contains("\"reason\":\"${reason.wire}\""))
        }
    }

    @Test fun `UTF8 bounds count bytes not code units`() {
        assertNotNull(ContentReportProtocol.prepare(draft("界".repeat(2000))))
        assertNull(ContentReportProtocol.prepare(draft("界".repeat(2001))))
        assertNotNull(ContentReportProtocol.prepare(draft().copy(note = "😀".repeat(250))))
        assertNull(ContentReportProtocol.prepare(draft().copy(note = "😀".repeat(251))))
    }

    @Test fun `envelope escaping can reject a report within content and raw limits`() {
        // Each control character expands to six JSON bytes. The receipt envelope must also fit.
        val prefix = "x" + "\u0001".repeat(1320)
        assertTrue(prefix.toByteArray().size < 6000)
        assertNull(ContentReportProtocol.prepare(draft(prefix)))
        assertNotNull(ContentReportProtocol.prepare(draft("x" + "\u0001".repeat(1200))))
    }

    @Test fun `empty invalid Unicode wrong UUID and unsafe version are rejected`() {
        for (content in listOf("", " \t\r\n", "\ufeff", "\uD800", "\uDC00", "x\uD800z"))
            assertNull(ContentReportProtocol.prepare(draft(content)))
        for (version in listOf("", "0.6 beta", "0.6\n", "界", "x".repeat(65), ".0.6"))
            assertNull(ContentReportProtocol.prepare(draft().copy(appVersion = version)))
        assertNull(ContentReportProtocol.prepare(draft().copy(reportId = id.uppercase())))
        assertNull(ContentReportProtocol.prepare(draft().copy(reportId = id.replace("4234", "1234"))))
        assertNull(ContentReportProtocol.prepare(draft().copy(note = "\uD800")))
    }

    @Test fun `initial preview fits bytes without splitting Unicode`() {
        val long = "a".repeat(5997) + "😀tail"
        assertEquals("a".repeat(5997), ContentReportProtocol.initialExcerpt(long))
        assertEquals("界".repeat(2000), ContentReportProtocol.initialExcerpt("界".repeat(2001)))
        assertEquals("Unchanged 😀", ContentReportProtocol.initialExcerpt("Unchanged 😀"))
    }

    @Test fun `only complete matching persisted receipt establishes success`() {
        assertEquals(ReportResult.Received(receipt, "2026-10-28T00:00:00.000Z"), ContentReportProtocol.receipt(response(), id))
        val invalid = listOf(
            "", "<html>Sign in</html>", "{}", "true", "{\"ok\":true}",
            response().replace("true", "\"true\""), response().replace("received", "accepted"),
            response(reportId = receipt), response(receiptId = "no-receipt"),
            response(time = "2026-02-30T00:00:00.000Z"), response(time = "2026-10-28T24:00:00.000Z"),
            response(time = "2026-10-28T00:00:60.000Z"), response(time = "2026-10-28T00:00:00+00:00"),
            response().dropLast(1), response() + "{}", response().replace("}", ",\"extra\":\"value\"}"),
            response().replace("{", "{\"ok\":false,"), response().replace("{", "{\"unknown\":{},"),
            response().replace("\"ok\"", "'ok'"), response().replace("}", ",}"),
        )
        invalid.forEach { assertEquals("Invalid receipt accepted", ReportResult.Unconfirmed, ContentReportProtocol.receipt(it, id)) }
    }

    @Test fun `only exact known rejection envelopes are decoded`() {
        for (code in listOf("invalid_request", "too_large", "conflict", "unavailable", "method_not_allowed"))
            assertEquals(ReportResult.Rejected(code), ContentReportProtocol.receipt("""{"ok":false,"code":"$code"}""", id))
        for (json in listOf("""{"ok":false,"code":"new-code"}""", """{"ok":false,"code":"unavailable","reportId":"$id"}"""))
            assertEquals(ReportResult.Unconfirmed, ContentReportProtocol.receipt(json, id))
    }

    @Test fun `manual retry preserves UUID and exact payload until a real edit`() {
        val original = draft()
        val attempted = original.copy(attempted = true)
        assertEquals(ContentReportProtocol.prepare(original), ContentReportProtocol.prepare(attempted))
        assertSame(attempted, attempted.edit())
        for (edited in listOf(attempted.edit(content = "Edited"), attempted.edit(note = "Edited"), attempted.edit(reason = ReportReason.HATE))) {
            assertNotEquals(attempted.reportId, edited.reportId)
            assertFalse(edited.attempted)
            assertEquals(edited.reportId, edited.edit(content = "Another edit").reportId)
        }
        assertEquals(original.reportId, original.edit(content = "Before first attempt").reportId)
    }
}
