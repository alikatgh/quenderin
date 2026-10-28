package ai.quenderin.app

import ai.quenderin.app.ui.OnboardingScreen
import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.core.OnboardingPhase
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
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
        compose.setContent {
            QuenderinTheme {
                OnboardingScreen(phase = phase, selection = null,
                    onStart = { phase = OnboardingPhase.Idle }, onAccept = {})
            }
        }
        compose.onNodeWithText(context.getString(R.string.onboarding_setup_failed)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.action_try_again)).performScrollTo().performClick()
        compose.onNodeWithTag("setup.startLocal").assertIsDisplayed()
        compose.onNodeWithTag("setup.computer").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("setup.deepseek").performScrollTo().assertIsDisplayed()
        println("UI_RECOVERY_PASSED injected failure preserves local and optional connection choices")
    }
}
