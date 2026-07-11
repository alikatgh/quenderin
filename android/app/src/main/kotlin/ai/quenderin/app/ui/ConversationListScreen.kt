@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package ai.quenderin.app.ui
import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R

import ai.quenderin.core.ConversationSummary
import ai.quenderin.core.ModelEntry
import android.text.format.DateUtils
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * The Chat tab's landing screen: a WhatsApp-style list of past conversations. Tap a row to open that
 * conversation; long-press for Delete; the "+" starts a new chat. Every conversation is with the same
 * on-device model, so each row is a past SESSION (title from its first message + when it was last
 * active). Twin of iOS `ConversationListView`.
 */
@Composable
fun ConversationListScreen(
    summaries: List<ConversationSummary>,
    model: ModelEntry,
    onOpen: (String) -> Unit,
    onNew: () -> Unit,
    onDelete: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 14.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.chats_title),
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f),
            )
            // New chat — a filled circular "+" (WhatsApp's compose button).
            val newChat = stringResource(R.string.chat_new)
            Box(
                Modifier
                    .size(44.dp)
                    .background(MaterialTheme.colorScheme.primary, CircleShape)
                    .semantics { contentDescription = newChat }
                    .combinedClickable(onClick = onNew, onLongClick = {}),
                contentAlignment = Alignment.Center,
            ) { PlusIcon(MaterialTheme.colorScheme.onPrimary) }
        }

        if (summaries.isEmpty()) {
            EmptyConversationList(model, Modifier.weight(1f), onNew)
        } else {
            LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                items(summaries, key = { it.id }) { summary ->
                    ConversationRow(summary, onOpen = { onOpen(summary.id) }, onDelete = { onDelete(summary.id) })
                }
            }
        }
    }
}

@Composable
private fun ConversationRow(summary: ConversationSummary, onOpen: () -> Unit, onDelete: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onOpen, onLongClick = { menuOpen = true })
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ModelAvatar(size = 48.dp)
            Spacer(Modifier.width(12.dp))
            // WhatsApp row anatomy: title over the last-message snippet, time in the top corner.
            Column(Modifier.weight(1f)) {
                Text(
                    summary.title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (summary.preview.isNotEmpty()) {
                    Text(
                        summary.preview,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.width(10.dp))
            Text(
                relativeTime(summary.updatedAt),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) },
                onClick = { menuOpen = false; onDelete() },
            )
        }
    }
}

@Composable
private fun EmptyConversationList(model: ModelEntry, modifier: Modifier, onNew: () -> Unit) {
    Column(
        modifier.fillMaxWidth().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        ModelAvatar(size = 72.dp)
        Spacer(Modifier.height(16.dp))
        Text(
            stringResource(R.string.chats_empty_title),
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.chats_empty_body, model.label),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 280.dp),
        )
        Spacer(Modifier.height(20.dp))
        Row(
            Modifier
                .background(MaterialTheme.colorScheme.primary, CircleShape)
                .combinedClickable(onClick = onNew, onLongClick = {})
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PlusIcon(MaterialTheme.colorScheme.onPrimary)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.chat_new), color = MaterialTheme.colorScheme.onPrimary, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Relative "last active" label — "just now", "5 min ago", "Yesterday", or a date. */
private fun relativeTime(epochMs: Long): String =
    DateUtils.getRelativeTimeSpanString(
        epochMs,
        System.currentTimeMillis(),
        DateUtils.MINUTE_IN_MILLIS,
        DateUtils.FORMAT_ABBREV_RELATIVE,
    ).toString()

@Composable
private fun PlusIcon(color: Color) {
    Canvas(Modifier.size(20.dp)) {
        val w = size.width; val h = size.height
        val sw = 2.4.dp.toPx()
        drawLine(color, androidx.compose.ui.geometry.Offset(w * 0.5f, h * 0.22f), androidx.compose.ui.geometry.Offset(w * 0.5f, h * 0.78f), sw, StrokeCap.Round)
        drawLine(color, androidx.compose.ui.geometry.Offset(w * 0.22f, h * 0.5f), androidx.compose.ui.geometry.Offset(w * 0.78f, h * 0.5f), sw, StrokeCap.Round)
    }
}
