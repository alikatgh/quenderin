package ai.quenderin.app

import ai.quenderin.app.ui.OnboardingScreen
import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.app.ui.RetainedDestination
import ai.quenderin.core.OnboardingPhase
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.junit.Test
import org.junit.runner.RunWith

/** Failure injection exercises the real setup UI; it is not a reproduced device/download failure. */
@RunWith(AndroidJUnit4::class)
class OnboardingRecoveryTest {
    private val compose = createComposeRule()
    private val failures = object : TestWatcher() {
        override fun failed(error: Throwable, description: Description) {
            runCatching { ScreenshotEvidence.capture("08-failure.png") }
        }
    }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(compose).around(failures)

    @Test
    fun failedSetupKeepsChoicesAndCanReturnToLocalSetup() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var phase by mutableStateOf<OnboardingPhase>(OnboardingPhase.Failed("Synthetic setup failure"))
        var showRetainedLayers by mutableStateOf(false)
        var visibleActions = 0
        var hiddenActions = 0
        compose.setContent {
            QuenderinTheme {
                if (!showRetainedLayers) {
                    OnboardingScreen(phase = phase, selection = null,
                        onStart = { phase = OnboardingPhase.Idle }, onAccept = {})
                } else {
                    Box(Modifier.fillMaxSize().testTag("retained.surface")) {
                        RetainedDestination(visible = true) {
                            Box(Modifier.fillMaxSize()) {
                                Button(onClick = { visibleActions++ },
                                    modifier = Modifier.align(Alignment.TopStart).padding(24.dp)
                                        .testTag("retained.visibleAction")) { Text("Visible action") }
                            }
                        }
                        RetainedDestination(visible = false) {
                            Box(Modifier.fillMaxSize()) {
                                Button(onClick = { hiddenActions++ },
                                    modifier = Modifier.align(Alignment.Center)
                                        .testTag("retained.hiddenAction")) { Text("Hidden action") }
                            }
                        }
                    }
                }
            }
        }
        compose.onNodeWithText(context.getString(R.string.onboarding_setup_failed)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.action_try_again)).performScrollTo().performClick()
        compose.onNodeWithTag("setup.startLocal").assertIsDisplayed()
        compose.onNodeWithTag("setup.computer").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("setup.deepseek").performScrollTo().assertIsDisplayed()
        println("UI_RECOVERY_PASSED injected failure preserves local and optional connection choices")

        // Exercise the production retained-layer helper. A blank part of the active layer
        // overlaps a real hidden Button; semantic performClick would bypass hit testing.
        compose.runOnIdle { showRetainedLayers = true }
        compose.onNodeWithTag("retained.hiddenAction").assertDoesNotExist()
        val surfaceBounds = compose.onNodeWithTag("retained.surface").fetchSemanticsNode().boundsInRoot
        val hiddenBounds = compose.onNodeWithTag("retained.hiddenAction", useUnmergedTree = true)
            .fetchSemanticsNode().boundsInRoot
        val visibleBounds = compose.onNodeWithTag("retained.visibleAction").fetchSemanticsNode().boundsInRoot
        assertTrue("The hidden control must overlap the retained surface", surfaceBounds.contains(hiddenBounds.center))
        assertFalse("The hidden control must sit under active whitespace", visibleBounds.contains(hiddenBounds.center))
        val blankTap = hiddenBounds.center - surfaceBounds.topLeft
        compose.onNodeWithTag("retained.surface").performTouchInput { click(blankTap) }
        compose.runOnIdle {
            assertEquals("Blank active content must not activate a hidden control", 0, hiddenActions)
            assertEquals(0, visibleActions)
        }
        compose.onNodeWithTag("retained.visibleAction").performTouchInput { click(center) }
        compose.runOnIdle {
            assertEquals("Visible child gestures remain operable", 1, visibleActions)
            assertEquals(0, hiddenActions)
        }
        println("UI_RETAINED_POINTER_PASSED coordinate taps block hidden actions and preserve visible child gestures")
    }
}
