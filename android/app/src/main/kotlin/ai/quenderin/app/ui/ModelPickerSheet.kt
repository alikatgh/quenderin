package ai.quenderin.app.ui

import ai.quenderin.core.ModelCatalog
import ai.quenderin.core.ModelEntry
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Pick a different model: lists the catalog; selecting one downloads it (if needed) and loads it.
 * Shared by Settings ("Change model…") and the chat model-profile sheet, so the picker exists once.
 */
@Composable
internal fun ModelPickerSheet(currentModelId: String, onSelect: (ModelEntry) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        Text(
            "Choose a model",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 4.dp),
        )
        Text(
            "Switching downloads the model if it isn't already on your device.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        )
        Column(Modifier.fillMaxWidth().heightIn(max = 480.dp).verticalScroll(rememberScrollState())) {
            ModelCatalog.models.forEach { entry ->
                Row(
                    Modifier.fillMaxWidth().clickable { onSelect(entry) }.padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(entry.label)
                        Text(
                            entry.sizeLabel,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (entry.id == currentModelId) {
                        Text("Current", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }
    }
}
