package ai.quenderin.app.ui

import ai.quenderin.app.R
import ai.quenderin.app.BuildConfig
import ai.quenderin.app.contentreport.ContentReportViewModel
import ai.quenderin.app.contentreport.ReportSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp

/** Reuse the existing Markdown budget. Over-budget replies retain exact, selectable text in
 * bounded sections instead of creating an unbounded tree of Markdown layout nodes. */
@Composable
fun AssistantResponseText(text: String, color: Color, modifier: Modifier = Modifier) {
    if (remoteMarkdownFormattingAllowed(text)) {
        MarkdownText(text, color, modifier)
        return
    }
    val sections = remember(text) { remoteTextSections(text) }
    var section by remember(text) { mutableIntStateOf(0) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.response_plain), style = MaterialTheme.typography.bodySmall, color = color)
        SelectionContainer {
            Text(sections[section], color = color, style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()))
        }
        if (sections.size > 1) {
            Text(stringResource(R.string.response_section, section + 1, sections.size),
                style = MaterialTheme.typography.labelMedium, color = color)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { section-- }, enabled = section > 0, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.response_previous))
                }
                TextButton(onClick = { section++ }, enabled = section < sections.lastIndex, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.response_next))
                }
            }
        }
    }
}

/** One restrained, labeled action row, shared by every assistant response destination. */
@Composable
fun ResponseActions(text: String, source: ReportSource, modifier: Modifier = Modifier) {
    if (text.isBlank()) return
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val copied = stringResource(R.string.response_copied)
    val reportModel: ContentReportViewModel = viewModel()
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        TextButton(onClick = {
            clipboard.setText(AnnotatedString(text))
            android.widget.Toast.makeText(context, copied, android.widget.Toast.LENGTH_SHORT).show()
        }, modifier = Modifier.heightIn(min = 48.dp).testTag("response.copy")) {
            Text(stringResource(R.string.response_copy))
        }
        TextButton(onClick = {
            reportModel.open(text, source, BuildConfig.VERSION_NAME)
        }, modifier = Modifier.heightIn(min = 48.dp).testTag("response.report")) {
            Text(stringResource(R.string.response_report))
        }
    }
}
