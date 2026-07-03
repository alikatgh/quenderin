package ai.quenderin.app.ui

import ai.quenderin.core.SupportContact
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * The very first screen a new user sees — ONE calm page, before the model-setup flow:
 * who Quenderin is (the elf), the three things that make it different (private, offline,
 * open source), and a single Continue. Shown once (SharedPreferences flag in AppRoot);
 * twin of iOS `WelcomeView`.
 */
@Composable
fun WelcomeScreen(onContinue: () -> Unit) {
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        ModelAvatar(96.dp)
        Spacer(Modifier.height(18.dp))
        Text(
            "Meet Quenderin",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "A personal AI that lives on your phone — not in someone's cloud.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(28.dp))
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            WelcomeRow("Private by design", "Conversations never leave this phone. No account, no tracking.")
            WelcomeRow("Works offline", "Download a model once — then it answers anywhere, airplane mode included.")
            WelcomeRow("Open source", "Every line of Quenderin is public. Read it, star it, improve it.")
        }
        Spacer(Modifier.height(32.dp))
        Button(onClick = onContinue, modifier = Modifier.fillMaxWidth()) {
            Text("Continue", style = MaterialTheme.typography.titleMedium)
        }
        TextButton(onClick = {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.GITHUB_URL))) }
        }) {
            Text("View the source on GitHub", color = MaterialTheme.colorScheme.primary)
        }
    }
}

@Composable
private fun WelcomeRow(title: String, detail: String) {
    Row(verticalAlignment = Alignment.Top) {
        // A quiet brand-colored marker instead of an icon set the app doesn't ship.
        Text(
            "●",
            color = MaterialTheme.colorScheme.primary,
            style = MaterialTheme.typography.labelLarge,
        )
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                detail,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
