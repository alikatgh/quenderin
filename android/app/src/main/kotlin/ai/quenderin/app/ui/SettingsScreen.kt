package ai.quenderin.app.ui

import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.SupportContact
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Settings / manage — twin of iOS `SettingsView`. Shows the active model, on-device storage
 * (conversation count, read fresh from the index), and the in-app About/Privacy. Clearing
 * conversations lives in the chat History sheet, where the live coordinator is.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(model: ModelEntry, persistence: ConversationPersistence) {
    val context = LocalContext.current
    // Read on entry (the tab recomposes fresh each visit); the index file is tiny.
    val conversationCount = remember { persistence.loadIndex().size }

    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }) }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionHeader("Model")
            LabeledRow("Active model", model.label)
            LabeledRow("Size", model.sizeLabel)
            Caption("Runs entirely on-device via llama.cpp — no cloud.")

            SectionHeader("Storage")
            LabeledRow("Saved conversations", conversationCount.toString())
            Caption("Browse, switch, or clear conversations from the History button in Chat.")

            SectionHeader("Privacy & support")
            Caption(SupportContact.AI_DISCLAIMER)
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

            Caption(
                "Quenderin runs entirely on your device. No account, no cloud, no tracking — once a " +
                    "model is downloaded it works fully offline, and nothing you type leaves your phone.",
            )
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun LabeledRow(title: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title)
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
