package ai.quenderin.app.ui

import ai.quenderin.core.SupportContact
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * In-app About / Privacy — twin of iOS `AboutView`. Surfaces the on-device promise, the AI-content
 * disclaimer, a privacy-policy link, and a support contact (both stores prefer in-app privacy access;
 * Play increasingly expects it).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AboutScreen() {
    val context = LocalContext.current
    Scaffold(topBar = { TopAppBar(title = { Text("About") }) }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "Quenderin runs entirely on your device. No account, no cloud, no tracking — once a " +
                    "model is downloaded it works fully offline, and nothing you type leaves your phone.",
            )
            Text(
                SupportContact.AI_DISCLAIMER,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = {
                runCatching {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.PRIVACY_POLICY_URL)))
                }
            }) { Text("Privacy Policy") }
            OutlinedButton(onClick = {
                runCatching {
                    context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${SupportContact.REPORT_EMAIL}")))
                }
            }) { Text("Contact support") }
        }
    }
}
