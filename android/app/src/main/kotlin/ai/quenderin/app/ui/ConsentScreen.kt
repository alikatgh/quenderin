package ai.quenderin.app.ui

import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R

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
 * The one screen every user must ACCEPT before using Quenderin — shown after [WelcomeScreen]
 * on fresh installs, and once to existing users who predate it (its own SharedPreferences
 * flag in AppRoot). Local models can be confidently wrong; here the user acknowledges that
 * the judgement — and the responsibility — stays with them. Twin of iOS `ConsentView`; the
 * copy lives in [SupportContact] so both platforms ship one wording.
 */
@Composable
fun ConsentScreen(onAgree: () -> Unit) {
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            "Use with judgement",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(28.dp))
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            ConsentRow("AI can be wrong", SupportContact.CONSENT_WRONG)
            ConsentRow("It is not advice", SupportContact.CONSENT_NOT_ADVICE)
            ConsentRow("You are in charge", SupportContact.CONSENT_RESPONSIBILITY)
        }
        Spacer(Modifier.height(24.dp))
        // The binding sentence, in full, right above the button that accepts it.
        Text(
            SupportContact.CONSENT_LEGAL,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(32.dp))
        Button(onClick = onAgree, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.consent_agree), style = MaterialTheme.typography.titleMedium)
        }
        TextButton(onClick = {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SupportContact.TERMS_URL))) }
        }) {
            Text(stringResource(R.string.consent_read_terms), color = MaterialTheme.colorScheme.primary)
        }
    }
}

@Composable
private fun ConsentRow(title: String, detail: String) {
    Row(verticalAlignment = Alignment.Top) {
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
