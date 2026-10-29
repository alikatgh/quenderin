package ai.quenderin.app

import android.app.UiModeManager
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.KeyEvent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.junit.runner.RunWith
import java.io.PrintWriter
import java.io.Writer

/** Real Compose journeys with the existing DEBUG-only mock engine AND downloader.
 * The runner denies all guest IP egress before this class starts. No keys or provider actions.
 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 35)
class NativeJourneysTest {
    private val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private var scenario: ActivityScenario<MainActivity>? = null
    private val watcher = object : TestWatcher() {
        override fun failed(error: Throwable, description: Description) {
            runCatching { logBackRouting("journey.failure") }
                .onFailure { println("UI_FAILURE_DIAGNOSTIC_UNAVAILABLE ${it.javaClass.simpleName}") }
            runCatching { screenshot("08-failure.png", settle = false) }
                .onFailure { println("UI_FAILURE_SCREENSHOT_UNAVAILABLE ${it.javaClass.simpleName}") }
        }
        override fun finished(description: Description) {
            scenario?.close()
            scenario = null
            shell("settings put system font_scale 1.0")
        }
    }

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(compose).around(watcher)

    @Test(timeout = 240_000)
    fun firstRunLocalChatConnectionsSettingsAndAdaptiveStates() {
        // This package is newly installed in the one ephemeral hosted AVD. No Mac/user app data.
        assertTrue(context.getSharedPreferences("quenderin", 0).edit().clear()
            .putBoolean("suggestBestModel", false).commit())
        appearance(dark = false, fontScale = "1.0")
        launch()
        awaitTag("welcome.continue")
        screenshot("01-welcome-light.png")
        clickScrolled("welcome.continue")
        awaitTag("consent.agree")
        compose.onNodeWithText(context.getString(R.string.consent_legal)).assertExists()
        clickScrolled("consent.agree")
        awaitTag("setup.startLocal")
        screenshot("02-setup-light.png")

        // Entry and Back only: do not enter credentials, authorize a host, connect or send.
        clickScrolled("setup.deepseek")
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag("deepseek.connect").fetchSemanticsNodes().isNotEmpty() ||
                compose.onAllNodesWithText("Connect your DeepSeek account").fetchSemanticsNodes().isNotEmpty()
        }
        back()
        awaitTag("setup.computer")
        clickScrolled("setup.computer")
        awaitTag("remote.back")
        back()
        awaitTag("setup.startLocal")

        // Decline the offered download by browsing and dismissing the model picker.
        clickScrolled("setup.startLocal")
        awaitTag("setup.download")
        clickScrolled("setup.chooseModel")
        compose.onNodeWithText(context.getString(R.string.picker_choose_model)).assertIsDisplayed()
        back()
        awaitTag("setup.download")
        compose.onNodeWithTag("nav.chat").assertDoesNotExist()
        clickScrolled("setup.download")
        awaitTag("nav.chat")
        compose.onNodeWithTag("nav.chat").assertIsSelected()
        compose.onNodeWithTag("chat.composer").performClick().performTextInput("Hello from a synthetic UI test")
        compose.onNodeWithTag("chat.send").performClick()
        compose.waitUntil(15_000) {
            compose.onAllNodesWithTag("response.copy").fetchSemanticsNodes().isNotEmpty()
        }
        // The immediate canned engine cannot establish streaming Stop/Continue behavior.
        println("UI_FIXTURE local response is canned; Stop/Continue and real inference are not established")
        hideKeyboardIfVisible()
        screenshot("03-chat-light.png")

        logBackRouting("peer.bar.composer.beforeTap")
        compose.onNodeWithTag("chat.composer").performClick()
        logBackRouting("peer.bar.composer.afterTap")
        // Semantic text insertion can request focus itself; establish the tap's IME result first.
        compose.waitUntil(10_000) { keyboardVisible() }
        compose.onNodeWithTag("chat.composer").performTextInput("Keep this local draft")
        compose.waitUntil(10_000) { keyboardVisible() }
        logBackRouting("peer.bar.before")
        compose.onNodeWithTag("nav.settings").performClick().assertIsSelected()
        logBackRouting("peer.bar.after")
        compose.waitUntil(10_000) { !keyboardVisible() }
        assertHiddenComposerInactive()
        logBackRouting("responses.scroll.before")
        compose.onNodeWithTag("settings.responses").performScrollTo()
        logBackRouting("responses.click.before")
        compose.onNodeWithTag("settings.responses").performClick()
        awaitTag("settings.back")
        logBackRouting("responses.before")
        back()
        logBackRouting("responses.after")
        awaitSettingsRoot()
        // A hidden Chat Back handler must not consume Settings' subordinate-page return.
        compose.onNodeWithTag("nav.settings").assertIsSelected()
        compose.onNodeWithTag("nav.chat").performClick().assertIsSelected()
        compose.onNodeWithTag("chat.composer").assertTextEquals("Keep this local draft")

        // Re-enter from persisted synthetic history after a system appearance change. This is
        // distinct from the tab-switch draft retention asserted above.
        close()
        appearance(dark = true, fontScale = "1.0")
        launch()
        enterMockChat()
        assertEquals(Configuration.UI_MODE_NIGHT_YES,
            context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK)
        compose.onNodeWithTag("chat.composer").performClick().performTextInput("A dark-mode keyboard draft")
        compose.waitUntil(10_000) { keyboardVisible() }
        screenshot("05-chat-dark-keyboard.png")
        back()
        compose.waitUntil(10_000) { !keyboardVisible() }
        compose.onNodeWithTag("chat.composer").assertTextEquals("A dark-mode keyboard draft")
        compose.onNodeWithTag("nav.chat").assertIsSelected()

        close()
        appearance(dark = false, fontScale = "2.0")
        launch()
        awaitTag("setup.startLocal")
        assertTrue(context.resources.configuration.fontScale >= 1.99f)
        screenshot("06-setup-large-text.png")
        // Scroll to the actual actions at 200%; do not clamp fontScale to fit.
        enterMockChat()
        scenario!!.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
        compose.waitUntil(10_000) {
            context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        }
        enterMockChat()
        compose.onNodeWithTag("chat.composer").performClick().performTextInput("A rail keyboard draft")
        compose.waitUntil(10_000) { keyboardVisible() }
        logBackRouting("peer.rail.before")
        compose.onNodeWithTag("nav.settings").performClick().assertIsSelected()
        logBackRouting("peer.rail.after")
        compose.waitUntil(10_000) { !keyboardVisible() }
        assertHiddenComposerInactive()
        awaitSettingsRoot()
        screenshot("07-settings-short-window.png")
        val chat = compose.onNodeWithTag("nav.chat").fetchSemanticsNode().boundsInRoot
        val settings = compose.onNodeWithTag("nav.settings").fetchSemanticsNode().boundsInRoot
        assertTrue("Wide current window should use a navigation rail", kotlin.math.abs(chat.center.x - settings.center.x) < 2f)
        clickScrolled("settings.models")
        awaitTag("settings.back")
        compose.onNodeWithTag("settings.back").assertIsDisplayed().assertIsEnabled()
        logBackRouting("models.before")
        back()
        logBackRouting("models.after")
        awaitSettingsRoot()
        compose.onNodeWithTag("nav.settings").assertIsSelected()
        compose.onNodeWithTag("nav.chat").performClick().assertIsSelected()
        compose.onNodeWithTag("chat.composer").assertTextEquals("A rail keyboard draft").assertIsEnabled()
    }

    private fun enterMockChat() {
        compose.waitUntil(15_000) { exists("setup.startLocal") || exists("nav.chat") }
        if (exists("setup.startLocal")) {
            clickScrolled("setup.startLocal")
            awaitTag("setup.download")
            clickScrolled("setup.download")
        }
        awaitTag("nav.chat")
        compose.onNodeWithTag("nav.chat").performClick()
        if (exists("chats.new")) compose.onNodeWithTag("chats.new").performClick()
        awaitTag("chat.composer")
    }

    private fun assertHiddenComposerInactive() {
        // Disabled editors may omit Focused because they are no longer focusable.
        compose.onNodeWithTag("chat.composer", useUnmergedTree = true).assertIsNotEnabled()
            .assert(SemanticsMatcher("Focused is absent or false") {
                it.config.getOrNull(SemanticsProperties.Focused) != true
            })
    }
    private fun exists(tag: String): Boolean = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
    private fun awaitSettingsRoot() {
        // Verify the actual root destination and that its retained layer does not disable it.
        awaitTag("settings.responses")
        compose.onNodeWithTag("settings.root").assertIsEnabled()
        compose.onNodeWithTag("settings.back").assertDoesNotExist()
        compose.onNodeWithTag("nav.settings").assertIsSelected()
    }
    private fun awaitTag(tag: String) = compose.awaitJourneyTag(tag)
    private fun clickScrolled(tag: String) { compose.onNodeWithTag(tag).performScrollTo().performClick() }
    private fun back() { instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK); compose.waitForIdle() }
    private fun logBackRouting(phase: String) {
        // Compose queries synchronize with the UI thread; read only these two status fields
        // here, before entering onActivity's main-thread callback.
        val composerStatus = runCatching {
            val config = compose.onAllNodesWithTag("chat.composer", useUnmergedTree = true)
                .fetchSemanticsNodes().singleOrNull()?.config
            config?.getOrNull(SemanticsProperties.Focused) to config?.contains(SemanticsProperties.Disabled)
        }.getOrNull()
        val record = StringBuilder("phase=$phase")
            .append(" composerFocused=${composerStatus?.first} composerDisabled=${composerStatus?.second}")
        scenario!!.onActivity { activity ->
            val decor = activity.window.decorView
            val imeVisible = ViewCompat.getRootWindowInsets(decor)?.isVisible(WindowInsetsCompat.Type.ime()) == true
            val focusedView = activity.currentFocus
            val focusedClass = focusedView?.javaClass?.name?.take(128)
                ?.map { if (it.code in 32..126) it else '?' }?.joinToString("")
            record.append(" uptimeMs=${SystemClock.uptimeMillis()} lifecycle=${activity.lifecycle.currentState}")
                .append(" windowFocus=${decor.hasWindowFocus()} imeVisible=$imeVisible")
                .append(" androidFocusClass=$focusedClass androidFocusIsEditor=${focusedView?.onCheckIsTextEditor()}")
                .append(" androidXEnabledCallbacks=${activity.onBackPressedDispatcher.hasEnabledCallbacks()}")
            val fields = listOf("Top Callback:", "Callbacks:", "Callback:", "mLastProgress=",
                "mTriggerBack=", "mIsPreCommitAnimationInProgress=", "mStartRootScrollY=",
                "isBackAnimationAllowed=", "isAdjustPan=", "isHideAnimationInProgress=")
            // Activity.dump is public. Android 15 delegates to ViewRootImpl.dump, whose
            // Back/IME sections use println(String). Discard every other write immediately;
            // neither the complete dump nor the view hierarchy is buffered or persisted.
            val discard = object : Writer() {
                override fun write(buffer: CharArray, offset: Int, count: Int) = Unit
                override fun flush() = Unit
                override fun close() = Unit
            }
            var routingSection = false
            var truncated = false
            object : PrintWriter(discard) {
                override fun println(value: String?) {
                    val line = value?.trim() ?: return
                    if (line == "WindowOnBackDispatcher:" || line == "ImeBackAnimationController:") {
                        routingSection = true
                    } else if (!routingSection || (line != "<None>" && fields.none { line.startsWith(it) })) {
                        routingSection = false
                        return
                    }
                    val safe = line.take(512).map { if (it.code in 32..126) it else '?' }.joinToString("")
                    if (record.length + safe.length + 3 <= 4_000) record.append(" | ").append(safe)
                    else truncated = true
                }
            }.use { activity.dump("", null, it, emptyArray()) }
            if (truncated) record.append(" | truncated=true")
        }
        check(record.toString().toByteArray(Charsets.UTF_8).size <= 4_096)
        instrumentation.sendStatus(0, Bundle().apply { putString("quenderin.back.diagnostic", record.toString()) })
    }
    private fun hideKeyboardIfVisible() {
        if (keyboardVisible()) {
            back()
            compose.waitUntil(10_000) { !keyboardVisible() }
        }
    }
    private fun keyboardVisible(): Boolean {
        var visible = false
        scenario?.onActivity {
            visible = ViewCompat.getRootWindowInsets(it.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == true
        }
        return visible
    }
    private fun launch() {
        scenario = ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
            .putExtra("quenderin.mock_ui", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        compose.waitForIdle()
    }
    private fun close() { scenario?.close(); scenario = null }
    private fun appearance(dark: Boolean, fontScale: String) {
        shell("settings put system font_scale $fontScale")
        shell("settings put secure show_ime_with_hard_keyboard 1")
        instrumentation.runOnMainSync {
            context.getSystemService(UiModeManager::class.java).setApplicationNightMode(
                if (dark) UiModeManager.MODE_NIGHT_YES else UiModeManager.MODE_NIGHT_NO)
        }
    }
    private fun shell(command: String) {
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .bufferedReader().use { it.readText() }
    }
    private fun screenshot(name: String, settle: Boolean = true) {
        if (settle) compose.waitForIdle()
        ScreenshotEvidence.capture(name, renderedNode = if (settle) compose.onRoot(useUnmergedTree = true) else null)
    }
}
