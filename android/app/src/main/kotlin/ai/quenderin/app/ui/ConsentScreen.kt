package ai.quenderin.app.ui

import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R

import ai.quenderin.core.SupportContact
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
 * The one screen every user must ACCEPT before using Quenderin — shown after [WelcomeScreen]
 * on fresh installs, and once to existing users who predate it (its own SharedPreferences
 * flag in AppRoot). Local models can be confidently wrong; here the user acknowledges that
 * the judgement — and the responsibility — stays with them. Twin of iOS `ConsentView`; the
 * copy lives in the localized string catalog (consent_* keys, generated from the shared
 * scripts/translations.tsv rows), so ru/ko/ja/zh users read the disclaimer in their language.
 */
@Composable
fun ConsentScreen(onAgree: () -> Unit) {
    val context = LocalContext.current
    FirstContactFrame {
        Text(
            stringResource(R.string.consent_use_judgement),
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            // Same wording as SupportContact.CONSENT_* (shared with iOS) via the string catalog,
            // so ru/ko/ja/zh users read the disclaimer in their language.
            ConsentRow(stringResource(R.string.consent_wrong_title), stringResource(R.string.consent_wrong_body))
            ConsentRow(stringResource(R.string.consent_advice_title), stringResource(R.string.consent_advice_body))
            ConsentRow(stringResource(R.string.consent_charge_title), stringResource(R.string.consent_charge_body))
        }
        // The binding sentence, in full, right above the button that accepts it.
        Text(
            stringResource(R.string.consent_legal),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Start,
        )
        Button(onClick = onAgree, modifier = Modifier.fillMaxWidth().testTag("consent.agree")) {
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
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
