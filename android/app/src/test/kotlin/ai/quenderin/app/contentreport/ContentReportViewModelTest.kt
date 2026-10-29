package ai.quenderin.app.contentreport

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ContentReportViewModelTest {
    @Test fun `duplicate clicks are gated and manual retry reuses the exact attempted request`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val model = ContentReportViewModel(dispatcher)
            val requests = mutableListOf<PreparedReport>()
            val sender: (PreparedReport) -> ReportResult = { requests += it; ReportResult.Unconfirmed }
            assertTrue(model.open("Synthetic excerpt", ReportSource.LOCAL_CHAT, "0.6.0"))
            model.send(sender)
            assertTrue(model.state.value.busy)
            assertTrue(model.state.value.visible)
            assertFalse(model.close())
            assertTrue(model.state.value.visible)
            model.send(sender)
            assertFalse(model.open("Another message", ReportSource.AGENT, "0.6.0"))
            model.edit(content = "Edit during send")
            assertEquals("Synthetic excerpt", model.state.value.draft!!.content)
            runCurrent()
            assertEquals(1, requests.size)
            assertFalse(model.state.value.busy)
            assertEquals(ReportResult.Unconfirmed, model.state.value.result)
            assertTrue(model.close())
            assertFalse(model.state.value.visible)
            val closedDraft = model.state.value.draft
            assertTrue(model.open("Synthetic excerpt", ReportSource.LOCAL_CHAT, "0.6.0"))
            assertTrue(model.state.value.visible)
            assertEquals(closedDraft, model.state.value.draft)
            model.send(sender)
            runCurrent()
            assertEquals(listOf(requests.first(), requests.first()), requests)
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `opening same selected message retains edited draft and reconciliation ID without a replay`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val model = ContentReportViewModel(dispatcher)
            model.open("Synthetic excerpt", ReportSource.REMOTE, "0.6.0")
            model.edit(content = "User-approved preview", note = "Synthetic note", reason = ReportReason.VIOLENCE)
            var sends = 0
            model.send { sends++; ReportResult.Rejected("unavailable") }
            runCurrent()
            val state = model.state.value
            assertTrue(model.open("Synthetic excerpt", ReportSource.REMOTE, "0.6.0"))
            assertEquals(state, model.state.value)
            assertEquals(1, sends)
            model.edit(note = "Changed after ambiguous send")
            assertNotEquals(state.draft!!.reportId, model.state.value.draft!!.reportId)
            assertFalse(model.state.value.draft!!.attempted)
            assertNull(model.state.value.result)
            assertEquals(state.selectionId, model.state.value.selectionId)
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `receipt is retained and a new ViewModel does not restore or replay sensitive content`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val model = ContentReportViewModel(dispatcher)
            model.open("Synthetic excerpt", ReportSource.DEEPSEEK, "0.6.0")
            val receipt = ReportResult.Received("87654321-4321-4321-8321-cba987654321", "2026-10-28T00:00:00.000Z")
            var sends = 0
            model.send { sends++; receipt }
            runCurrent()
            model.send { sends++; receipt }
            runCurrent()
            assertEquals(1, sends)
            assertEquals(receipt, model.state.value.result)
            val fresh = ContentReportViewModel(dispatcher)
            assertNull(fresh.state.value.draft)
            assertNull(fresh.state.value.selectionId)
            assertFalse(fresh.state.value.visible)
            assertFalse(fresh.state.value.busy)
            runCurrent()
            assertEquals(1, sends)
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `conflict needs a real edit before another send and exceptions preserve draft`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val model = ContentReportViewModel(dispatcher)
            model.open("Synthetic excerpt", ReportSource.STEP5, "0.6.0")
            var sends = 0
            model.send { sends++; ReportResult.Rejected("conflict") }
            runCurrent()
            val attempted = model.state.value.draft!!
            model.edit(reason = attempted.reason) // A selected-row click is not a real edit.
            model.send { sends++; ReportResult.Unconfirmed }
            runCurrent()
            assertEquals(1, sends)
            model.edit(content = "User edited excerpt")
            assertNotEquals(attempted.reportId, model.state.value.draft!!.reportId)
            model.send { sends++; throw IllegalStateException("Synthetic failure") }
            runCurrent()
            assertEquals(2, sends)
            assertEquals("User edited excerpt", model.state.value.draft!!.content)
            assertEquals(ReportResult.Unconfirmed, model.state.value.result)
            assertFalse(model.state.value.busy)
        } finally { Dispatchers.resetMain() }
    }
}
