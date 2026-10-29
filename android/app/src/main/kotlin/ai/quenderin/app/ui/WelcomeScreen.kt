package ai.quenderin.app.ui

import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R

import ai.quenderin.core.SupportContact
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * The first entry explains the immediate choice before consent and setup. No account or tour is
 * required; the next setup page offers local, DeepSeek and paired-computer actions.
 */
@Composable
fun WelcomeScreen(onContinue: () -> Unit) {
    val context = LocalContext.current
    FirstContactFrame {
        ModelAvatar(56.dp)
        Text(
            stringResource(R.string.welcome_title),
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            stringResource(R.string.entry_welcome_body),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Start,
        )
        Text(
            stringResource(R.string.entry_private_detail),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onContinue, modifier = Modifier.fillMaxWidth().testTag("welcome.continue")) {
            Text(stringResource(R.string.action_continue), style = MaterialTheme.typography.titleMedium)
        }
        TextButton(onClick = {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.GITHUB_URL))) }
        }) {
            Text(stringResource(R.string.welcome_view_source), color = MaterialTheme.colorScheme.primary)
        }
    }
}
