package ai.quenderin.app

import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.app.ui.RemoteHarnessScreen
import android.app.UiModeManager
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.activity.compose.setContent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.junit.runner.RunWith

/** Rendered Bot proof only: actual Compose/controller/core, synthetic relay/crypto/history.
 * No live Host, real inference, signing or release-runtime claim follows from this test. */
@RunWith(AndroidJUnit4::class)
class BotHistoryJourneyTest {
    private val compose = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private var controller: RemoteHarnessController? = null
    private val watcher = object : TestWatcher() {
        override fun failed(error: Throwable, description: Description) {
            runCatching { ScreenshotEvidence.capture("08-failure.png") }
        }
        override fun finished(description: Description) {
            scenario?.onActivity { controller?.close() }
            scenario?.close(); scenario = null; controller = null
        }
    }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(compose).around(watcher)

    @Test(timeout = 120_000)
    fun botRosterOpensHistoryWithoutComposerOrModelMutation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.runOnMainSync {
            context.getSystemService(UiModeManager::class.java).setApplicationNightMode(UiModeManager.MODE_NIGHT_NO)
        }
        val fixture = BotJourneyFixture()
        scenario = ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
            .putExtra("quenderin.mock_ui", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        scenario!!.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
        compose.waitUntil(10_000) { context.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT }
        scenario!!.onActivity { activity ->
            val remote = RemoteHarnessController(activity) { _, schedule -> fixture.client(schedule) to true }
            controller = remote
            activity.setContent { QuenderinTheme { RemoteHarnessScreen(remote, onBack = {}) } }
        }
        compose.waitUntil(10_000) { controller?.securityAvailable == true }
        // Synthetic account values never leave the in-memory API; guest IP egress is denied.
        compose.runOnIdle { controller!!.authorize("https://synthetic.example.org", "fixture@example.org", "synthetic-only".toCharArray()) }
        await("remote.host.host-a")
        compose.onNodeWithTag("remote.host.host-a").performClick()
        await("remote.pinCompared")
        compose.onNodeWithTag("remote.pinCompared").performScrollTo().performClick()
        compose.onNodeWithTag("remote.confirmPin").performScrollTo().performClick()
        await("remote.workspace.workspace-a")
        compose.onNodeWithTag("remote.workspace.workspace-a").performClick()
        await("remote.botsReady")
        compose.onNodeWithTag("remote.session.ordinary-session").performScrollTo().performClick()
        await("remote.composer")
        // A session first renders its disabled composer while history and Bot classification load.
        compose.waitUntil(10_000) {
            val state = controller!!.state
            state.historyReady && state.models.isNotEmpty() && !state.botSessionClassificationPending && !state.busy
        }
        compose.onNodeWithTag("remote.composer").assertIsEnabled()
        compose.onNodeWithTag("remote.models").assertIsEnabled()
        compose.onNodeWithText("Synthetic saved ordinary answer").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Synthetic saved Bot answer").assertDoesNotExist()
        compose.runOnIdle {
            assertEquals("ordinary-session", controller!!.state.sessionID)
            assertEquals("ordinary-session", fixture.lastFollowSession.get())
        }
        // Ordinary sessions retain their composer and model controls; no task is dispatched.
        compose.onNodeWithTag("remote.more").performClick()
        compose.onNodeWithText("Sessions · Synthetic workspace").performClick()
        await("remote.botsReady")
        compose.onNodeWithTag("remote.bot.bot-a").performScrollTo().assertIsEnabled()
        compose.onNodeWithText("Synthetic researcher").assertIsDisplayed()
        compose.onNodeWithText("Model: deepseek-flash").assertIsDisplayed()
        compose.onNodeWithText("Permission: ask").assertIsDisplayed()
        val beforeRefresh = controller!!.state.botRoster!!.revision
        compose.onNodeWithTag("remote.refreshBots").performScrollTo().performClick()
        compose.waitUntil(10_000) { (controller!!.state.botRoster?.revision ?: 0) > beforeRefresh && !controller!!.state.botRosterLoading }
        compose.onNodeWithTag("remote.bot.bot-a").performScrollTo().assertIsEnabled()
        ScreenshotEvidence.capture("09-bot-roster.png", compose.onRoot())
        compose.onNodeWithTag("remote.bot.bot-a").performClick()
        await("remote.botSessionReadOnly")
        compose.waitUntil(10_000) { controller!!.state.historyReady }
        compose.onNodeWithText("Synthetic saved Bot answer").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Synthetic saved ordinary answer").assertDoesNotExist()
        compose.runOnIdle {
            assertEquals("bot-session", controller!!.state.sessionID)
            assertEquals("bot-session", fixture.lastFollowSession.get())
            assertTrue(controller!!.state.timeline.none { it.text.contains("Synthetic saved ordinary") })
        }
        compose.onNodeWithTag("remote.composer").assertDoesNotExist()
        compose.onNodeWithTag("remote.send").assertDoesNotExist()
        compose.onNodeWithTag("remote.models").assertDoesNotExist()
        ScreenshotEvidence.capture("10-bot-history.png", compose.onRoot())
        compose.runOnIdle {
            assertTrue(controller!!.state.botSessionReadOnly)
            assertEquals(0, fixture.prompts.get())
            assertEquals(0, fixture.modelChanges.get())
        }
        println("UI_BOT_FIXTURE roster refresh and history rendered; ordinary composer retained; Bot composer/model controls absent; no live Host")
    }
    @Test(timeout = 120_000)
    fun botComposerSubmitsOnceAndReconcilesLostACKAfterOwnerRelaunch() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val fixture = BotJourneyFixture(workSupported = true).apply { dropSubmissionACK = true }
        scenario = ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
            .putExtra("quenderin.mock_ui", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        scenario!!.onActivity { activity ->
            val remote = RemoteHarnessController(activity) { _, schedule -> fixture.client(schedule) to true }
            controller = remote
            activity.setContent { QuenderinTheme { RemoteHarnessScreen(remote, onBack = {}, botsOnly = true) } }
        }
        compose.waitUntil(10_000) { controller?.securityAvailable == true }
        compose.runOnIdle { controller!!.authorize("https://synthetic.example.org", "fixture@example.org", "synthetic-only".toCharArray()) }
        await("remote.host.host-a"); compose.onNodeWithTag("remote.host.host-a").performClick()
        await("remote.pinCompared"); compose.onNodeWithTag("remote.pinCompared").performScrollTo().performClick()
        compose.onNodeWithTag("remote.confirmPin").performScrollTo().performClick()
        await("remote.workspace.workspace-a"); compose.onNodeWithTag("remote.workspace.workspace-a").performClick()
        await("remote.botsReady")
        compose.onNodeWithTag("remote.createSession").assertDoesNotExist()
        compose.onNodeWithTag("remote.session.ordinary-session").assertDoesNotExist()
        compose.onNodeWithTag("remote.bot.bot-a").performScrollTo().performClick()
        compose.waitUntil(10_000) { controller!!.state.historyReady && controller!!.state.botWorkSupported && !controller!!.state.botRosterLoading }
        await("remote.composer")
        compose.onNodeWithTag("remote.models").assertDoesNotExist()
        val task = "Synthetic persistent Bot task from the Android composer"
        compose.onNodeWithTag("remote.composer").performTextInput(task)
        compose.onNodeWithTag("remote.send").performClick()
        compose.waitUntil(10_000) { fixture.submissions.get() == 1 && controller!!.state.botCommand?.state == ai.quenderin.core.RemoteHarnessBotCommandState.PENDING }
        compose.onNodeWithTag("remote.send").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(task, controller!!.state.draft) }
        // Close only this test's owner; same serialized store and synthetic Host receipt survive.
        val beforeClose = fixture.journalWrites.get()
        scenario!!.onActivity { controller!!.close() }
        compose.waitUntil(10_000) { fixture.journalWrites.get() > beforeClose }
        scenario!!.onActivity { activity ->
            val remote = RemoteHarnessController(activity) { _, schedule -> fixture.client(schedule) to true }
            controller = remote
            activity.setContent { QuenderinTheme { RemoteHarnessScreen(remote, onBack = {}, botsOnly = true) } }
        }
        compose.waitUntil(10_000) { controller!!.state.selectedBot?.botID == "bot-a" }
        compose.runOnIdle {
            assertEquals(task, controller!!.state.draft)
            assertEquals(1, fixture.submissions.get())
        }
        // Lifecycle recovery may already have reconnected. Explicit reconnect is needed only while closed.
        if (controller!!.state.phase == ai.quenderin.core.RemoteHarnessClientPhase.DISCONNECTED) {
            compose.onNodeWithTag("remote.reconnect").performClick()
        }
        compose.waitUntil(15_000) { fixture.queries.get() == 1 && controller!!.state.historyReady &&
            controller!!.state.botCommand?.state == ai.quenderin.core.RemoteHarnessBotCommandState.ACCEPTED && !controller!!.state.botCommandChecking }
        compose.onNodeWithTag("remote.botCommandStatus").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Task accepted by Bot · completion comes from history").assertIsDisplayed()
        compose.onNodeWithTag("remote.composer").assertIsEnabled()
        compose.onNodeWithTag("remote.send").assertIsNotEnabled()
        ScreenshotEvidence.capture("11-bot-work.png", compose.onRoot())
        compose.runOnIdle {
            assertEquals(1, fixture.submissions.get())
            assertEquals(1, fixture.queries.get())
            assertEquals(0, fixture.prompts.get())
            assertEquals(0, fixture.modelChanges.get())
            assertEquals("", controller!!.state.draft)
        }
        println("UI_BOT_WORK_FIXTURE actual Composer/client submitted once; lost ACK reconciled after owner relaunch; no replay or live Host")
    }
    private fun await(tag: String) = compose.awaitJourneyTag(tag)
}
