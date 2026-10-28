package ai.quenderin.app

import ai.quenderin.app.contentreport.ContentReportProtocol
import ai.quenderin.app.contentreport.ContentReportViewModel
import ai.quenderin.app.contentreport.PreparedReport
import ai.quenderin.app.contentreport.ReportResult
import ai.quenderin.app.contentreport.ReportSource
import ai.quenderin.app.ui.LocalContentReportSender
import ai.quenderin.app.ui.ContentReportHost
import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.app.ui.ResponseActions
import android.app.UiModeManager
import android.content.pm.ActivityInfo
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import androidx.activity.compose.setContent
import androidx.test.core.app.ActivityScenario
import android.content.Intent
import android.content.res.Configuration
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.lifecycle.ViewModelProvider
import ai.quenderin.core.AutomaticSelectionMode
import ai.quenderin.core.OnboardingModel
import ai.quenderin.core.FileConversationPersistence
import java.io.File
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.junit.runner.RunWith

/** Injected sender cannot reach ContentReportTransport or any network endpoint. */
@RunWith(AndroidJUnit4::class)
class ContentReportJourneyTest {
    private val compose = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val failures = object : TestWatcher() {
        override fun failed(error: Throwable, description: Description) {
            runCatching { ScreenshotEvidence.capture("08-failure.png") }
        }
        override fun finished(description: Description) { scenario?.close(); scenario = null }
    }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(compose).around(failures)

    @Test
    fun editedPreviewRequiresExplicitSendAndManualRetryKeepsExactRequest() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            instrumentation.targetContext.getSystemService(UiModeManager::class.java)
                .setApplicationNightMode(UiModeManager.MODE_NIGHT_NO)
        }
        // Only the newly installed hosted-test package is used. Keep existing synthetic
        // conversations while forcing the real app through local mock setup below.
        assertTrue(instrumentation.targetContext.getSharedPreferences("quenderin", 0).edit()
            .putBoolean("hasWelcomed", true).putBoolean("disclaimerAccepted", true)
            .putBoolean("suggestBestModel", false).putBoolean("remoteComputerOpen", false)
            .putBoolean(AutomaticSelectionMode.PREFERENCE_KEY, false)
            .remove(OnboardingModel.ACTIVE_MODEL_PREFS_KEY).remove(AutomaticSelectionMode.MANUAL_MODEL_KEY).commit())
        scenario = ActivityScenario.launch<MainActivity>(Intent(instrumentation.targetContext, MainActivity::class.java)
            .putExtra("quenderin.mock_ui", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        scenario!!.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
        compose.waitUntil(10_000) {
            instrumentation.targetContext.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        }
        actualAppRootRetainsReportAcrossRecreation()
        val attempts = CopyOnWriteArrayList<PreparedReport>()
        val original = "Synthetic assistant response chosen by the user. Unshared conversation context stays outside the report."
        val completed = mutableStateOf(false)
        val excerpt = "Synthetic excerpt selected for review."
        val note = "Synthetic reviewer note."
        val receipt = "11111111-1111-4111-8111-111111111111"
        val sender: (PreparedReport) -> ReportResult = { prepared ->
            attempts += prepared
            if (attempts.size == 1) ReportResult.Unconfirmed else ContentReportProtocol.receipt(
                "{\"ok\":true,\"code\":\"received\",\"reportId\":\"${prepared.reportId}\",\"receiptId\":\"$receipt\",\"receivedAt\":\"2026-10-28T00:00:00.000Z\"}",
                prepared.reportId)
        }
        fun installFixture() {
            // Reinstall this test-owned composition after recreation. The actual Activity's
            // ViewModelStore retains the draft, presentation and request owner in RAM.
            scenario!!.onActivity { activity ->
                activity.setContent {
                    QuenderinTheme {
                        CompositionLocalProvider(LocalContentReportSender provides sender) {
                            Column(Modifier.fillMaxSize().padding(24.dp)) {
                                ContentReportHost(securePolicy = SecureFlagPolicy.SecureOff)
                                if (completed.value) key("final-response") {
                                    Text("Synthetic completed assistant response.", Modifier.testTag("fixture.final"))
                                    ResponseActions("Synthetic completed assistant response.", ReportSource.LOCAL_CHAT)
                                } else key("partial-response") {
                                    Text(original)
                                    ResponseActions(original, ReportSource.LOCAL_CHAT)
                                }
                            }
                        }
                    }
                }
            }
            compose.waitForIdle()
        }
        installFixture()
        compose.onNodeWithTag("response.report").performClick()
        compose.onNodeWithTag("contentReport.excerpt").assertTextContains(original)
            .performScrollTo().performTextReplacement(excerpt)
        compose.onNodeWithTag("contentReport.reason.violence").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithTag("contentReport.note").performScrollTo().performTextReplacement(note)
        compose.runOnIdle { assertEquals("Opening and editing never dispatches a report", 0, attempts.size) }
        scenario!!.recreate()
        installFixture()
        compose.onNodeWithTag("contentReport.dialog").assertExists()
        compose.onNodeWithTag("contentReport.excerpt").assertTextContains(excerpt)
        compose.onNodeWithTag("contentReport.note").assertTextContains(note)
        compose.onNodeWithTag("contentReport.reason.violence").assertIsSelected()
        compose.runOnIdle { assertEquals("Recreation never dispatches a report", 0, attempts.size) }
        // A streaming row is replaced after completion. The host must outlive either row.
        compose.runOnIdle { completed.value = true }
        compose.onNodeWithTag("contentReport.dialog").assertExists()
        compose.onNodeWithTag("contentReport.excerpt").assertTextContains(excerpt)
        compose.onNodeWithTag("contentReport.note").assertTextContains(note)
        compose.onNodeWithTag("contentReport.reason.violence").assertIsSelected()
        assertEquals("Only the stable app-root host presents a dialog", 1,
            compose.onAllNodesWithTag("contentReport.dialog").fetchSemanticsNodes().size)
        compose.runOnIdle { assertEquals("Completion never dispatches a report", 0, attempts.size) }
        compose.onNodeWithTag("contentReport.send").performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(instrumentation.targetContext.getString(R.string.report_unconfirmed))
                .fetchSemanticsNodes().isNotEmpty() && attempts.size == 1
        }
        compose.onNodeWithTag("contentReport.excerpt").assertTextContains(excerpt)
        compose.onNodeWithTag("contentReport.note").assertTextContains(note)
        compose.onNodeWithTag("contentReport.status").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("contentReport.excerpt").performScrollTo()
        compose.waitForIdle()
        ScreenshotEvidence.capture("04-report-light.png")
        compose.runOnIdle {
            assertTrue(attempts.single().json.contains("\"content\":\"$excerpt\""))
            assertTrue(attempts.single().json.contains("\"reason\":\"violence\""))
            assertTrue(attempts.single().json.contains("\"note\":\"$note\""))
            assertTrue(!attempts.single().json.contains(original))
        }
        compose.onNodeWithTag("contentReport.retry").performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(instrumentation.targetContext.getString(R.string.report_receipt, receipt))
                .fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("contentReport.status").assertTextContains(receipt, substring = true)
        compose.runOnIdle {
            assertEquals(2, attempts.size)
            assertEquals("Manual retry preserves the exact UUID and payload", attempts[0], attempts[1])
        }
        compose.onNodeWithTag("contentReport.close").performClick()
        compose.onNodeWithTag("contentReport.dialog").assertDoesNotExist()
        compose.runOnIdle { assertEquals("Closing never resends", 2, attempts.size) }
        println("UI_REPORT_PASSED Activity recreation and partial-row replacement retained edited preview; injected ambiguous failure then verified synthetic receipt; exact manual-retry UUID/payload preserved; no transport invoked")
    }

    @Test
    fun stableHostSurvivesPartialRowReplacementWhileSendIsPending() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        scenario = ActivityScenario.launch<MainActivity>(Intent(instrumentation.targetContext, MainActivity::class.java)
            .putExtra("quenderin.mock_ui", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val completed = mutableStateOf(false)
        val attempts = CopyOnWriteArrayList<PreparedReport>()
        val started = CountDownLatch(1)
        val finishAttempt = CountDownLatch(1)
        val partial = "Synthetic partial response. Unselected context is not shared."
        val excerpt = "Synthetic edited excerpt while the model finishes."
        val note = "Synthetic note kept during the pending send."
        val receipt = "22222222-2222-4222-8222-222222222222"
        val sender: (PreparedReport) -> ReportResult = { prepared ->
            attempts += prepared
            if (attempts.size == 1) {
                started.countDown()
                check(finishAttempt.await(30, TimeUnit.SECONDS)) { "Synthetic sender was not released" }
                ReportResult.Unconfirmed
            } else ContentReportProtocol.receipt(
                "{\"ok\":true,\"code\":\"received\",\"reportId\":\"${prepared.reportId}\",\"receiptId\":\"$receipt\",\"receivedAt\":\"2026-10-28T00:00:00.000Z\"}",
                prepared.reportId)
        }
        try {
            scenario!!.onActivity { activity ->
                activity.setContent {
                    QuenderinTheme {
                        CompositionLocalProvider(LocalContentReportSender provides sender) {
                            Column(Modifier.fillMaxSize().padding(24.dp)) {
                                ContentReportHost(securePolicy = SecureFlagPolicy.SecureOff)
                                if (completed.value) key("final-response") {
                                    Text("Synthetic final response.", Modifier.testTag("fixture.final"))
                                    ResponseActions("Synthetic final response.", ReportSource.DEEPSEEK)
                                } else key("partial-response") {
                                    Text(partial)
                                    ResponseActions(partial, ReportSource.DEEPSEEK)
                                }
                            }
                        }
                    }
                }
            }
            compose.waitForIdle()
            compose.onNodeWithTag("response.report").performClick()
            compose.onNodeWithTag("contentReport.excerpt").performScrollTo().performTextReplacement(excerpt)
            compose.onNodeWithTag("contentReport.reason.hate").performScrollTo().performClick()
            compose.onNodeWithTag("contentReport.note").performScrollTo().performTextReplacement(note)
            compose.onNodeWithTag("contentReport.send").performClick()
            compose.waitUntil(10_000) { started.count == 0L }
            compose.runOnIdle { completed.value = true }
            compose.onNodeWithTag("contentReport.dialog").assertExists()
            compose.onNodeWithTag("contentReport.excerpt").assertTextContains(excerpt).assertIsNotEnabled()
            compose.onNodeWithTag("contentReport.note").assertTextContains(note).assertIsNotEnabled()
            compose.onNodeWithTag("contentReport.reason.hate").assertIsSelected()
            compose.onNodeWithTag("contentReport.close").assertIsNotEnabled()
            compose.runOnIdle {
                assertEquals("Completing the partial row does not repeat a pending POST", 1, attempts.size)
                assertTrue(attempts.single().json.contains("\"content\":\"$excerpt\""))
                assertTrue(attempts.single().json.contains("\"source\":\"deepseek\""))
                assertTrue(!attempts.single().json.contains(partial))
                assertTrue(!attempts.single().json.contains("Synthetic final response."))
            }
            finishAttempt.countDown()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithText(instrumentation.targetContext.getString(R.string.report_unconfirmed))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithTag("contentReport.excerpt").assertTextContains(excerpt)
            compose.onNodeWithTag("contentReport.note").assertTextContains(note)
            compose.onNodeWithTag("contentReport.retry").performClick()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithText(instrumentation.targetContext.getString(R.string.report_receipt, receipt))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            compose.runOnIdle {
                assertEquals(2, attempts.size)
                assertEquals("Retry after row replacement preserves the exact UUID and payload", attempts[0], attempts[1])
            }
            compose.onNodeWithTag("contentReport.close").performClick()
            compose.onNodeWithTag("contentReport.dialog").assertDoesNotExist()
        } finally { finishAttempt.countDown() }
        println("UI_REPORT_PENDING_PASSED Stable destination host survived partial-to-final row replacement during pending send; edited preview and exact retry request retained; no transport invoked")
    }

    /** This phase exercises the actual MainActivity/AppRoot composition, never setContent.
     * A persisted conversation is open before recreation. Mock weights do not exist on disk,
     * so the recreated real router returns to setup; the app-root report must remain above it. */
    private fun actualAppRootRetainsReportAcrossRecreation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        fun exists(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
        fun await(tag: String) = compose.waitUntil(15_000) { exists(tag) }
        await("setup.startLocal")
        compose.onNodeWithTag("setup.startLocal").performScrollTo().performClick()
        await("setup.download")
        compose.onNodeWithTag("setup.download").performScrollTo().performClick()
        await("nav.chat")
        compose.onNodeWithTag("nav.chat").performClick()
        if (exists("chats.new")) compose.onNodeWithTag("chats.new").performClick()
        await("chat.composer")
        val prompt = "Synthetic root report retention"
        compose.onNodeWithTag("chat.composer").performClick().performTextInput(prompt)
        compose.onNodeWithTag("chat.send").performClick()
        await("response.report")
        // The app's Up action persists immediately, independently of keyboard dismissal timing.
        compose.onNodeWithContentDescription(context.getString(R.string.chat_back_to_conversations)).performClick()
        await("chats.new")
        val store = FileConversationPersistence(File(context.filesDir, "conversations"))
        val saved = store.loadIndex().firstOrNull { summary -> store.loadTranscript(summary.id).any { it.text == prompt } }
        assertTrue("The actual app saved the synthetic conversation", saved != null)
        compose.onAllNodesWithText(saved!!.title).onFirst().performClick()
        await("response.report")
        compose.onNodeWithTag("response.report").performClick()
        val excerpt = "Synthetic real AppRoot edited preview."
        val note = "Synthetic note retained through the actual router."
        compose.onNodeWithTag("contentReport.excerpt").performScrollTo().performTextReplacement(excerpt)
        compose.onNodeWithTag("contentReport.reason.dangerous").performScrollTo().performClick()
        compose.onNodeWithTag("contentReport.note").performScrollTo().performTextReplacement(note)
        var reportId: String? = null
        scenario!!.onActivity { activity ->
            val state = ViewModelProvider(activity)[ContentReportViewModel::class.java].state.value
            reportId = state.draft!!.reportId
            assertTrue(state.visible && !state.busy && !state.draft!!.attempted)
        }
        scenario!!.recreate() // MainActivity installs its own AppRoot; do not reinstall a test host.
        await("contentReport.dialog")
        compose.onNodeWithTag("contentReport.excerpt").assertTextContains(excerpt)
        compose.onNodeWithTag("contentReport.note").assertTextContains(note)
        compose.onNodeWithTag("contentReport.reason.dangerous").assertIsSelected()
        assertEquals(1, compose.onAllNodesWithTag("contentReport.dialog").fetchSemanticsNodes().size)
        scenario!!.onActivity { activity ->
            val state = ViewModelProvider(activity)[ContentReportViewModel::class.java].state.value
            assertEquals(reportId, state.draft!!.reportId)
            assertTrue("Recreation retains presentation and never dispatches", state.visible && !state.busy && !state.draft!!.attempted)
        }
        compose.onNodeWithTag("contentReport.close").performClick()
        await("setup.startLocal")
        compose.onNodeWithTag("chat.composer").assertDoesNotExist()
        println("UI_REPORT_APPROOT_PASSED Actual saved conversation changed to setup after MainActivity recreation; app-root SecureOn report retained edited excerpt, reason, note and UUID without a send")
    }
}
