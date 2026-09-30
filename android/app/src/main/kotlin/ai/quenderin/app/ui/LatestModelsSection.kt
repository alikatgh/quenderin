package ai.quenderin.app.ui

import ai.quenderin.app.R
import ai.quenderin.app.modelReleaseRepository
import ai.quenderin.app.probeDeviceProfile
import ai.quenderin.core.AndroidModelSelector
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelReleaseRepository
import ai.quenderin.core.ModelReleaseSnapshot
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import ai.quenderin.core.ModelReleaseFeed

@Composable
internal fun LatestModelsSection(onSelect: (ModelEntry) -> Unit) {
    val context = LocalContext.current
    val uri = LocalUriHandler.current
    val profile = remember { context.probeDeviceProfile() }
    val scope = rememberCoroutineScope()
    var repository by remember { mutableStateOf<ModelReleaseRepository?>(null) }
    var snapshot by remember { mutableStateOf<ModelReleaseSnapshot?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    var unavailable by remember { mutableStateOf(false) }
    var maxGB by remember { mutableStateOf(3) }
    var showAll by remember { mutableStateOf(false) }

    suspend fun refresh(force: Boolean = false) {
        if (refreshing) return
        refreshing = true
        try {
            val repo = repository ?: withContext(Dispatchers.IO) { modelReleaseRepository(context) }.also { repository = it }
            snapshot = repo.snapshot
            snapshot = withContext(Dispatchers.IO) { repo.refresh(force) }
            unavailable = false
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            unavailable = true
        } finally { refreshing = false }
    }

    LaunchedEffect(Unit) { refresh() }
    Column(Modifier.fillMaxWidth().padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.releases_title), style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.semantics { heading() })
        Text(stringResource(R.string.releases_explanation), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(3, 6, 24).forEach { limit ->
                FilterChip(selected = maxGB == limit, onClick = { maxGB = limit },
                    label = { Text(if (limit == 24) stringResource(R.string.releases_all_sizes) else "≤ $limit GB") })
            }
        }
        snapshot?.let { saved ->
            val date = ModelReleaseFeed.instant(saved.feed.checkedAt)?.atZone(ZoneId.systemDefault())
                ?.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT)) ?: saved.feed.checkedAt
            val status = stringResource(if (saved.saved) R.string.releases_saved else R.string.releases_live)
            val partial = if (saved.feed.partial) stringResource(R.string.releases_partial) else ""
            val failed = if (saved.refreshFailed) stringResource(R.string.releases_refresh_failed) else ""
            Text("$status · $date$partial$failed", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            val filtered = saved.feed.models.filter { it.downloadGB <= maxGB }
            if (filtered.isEmpty()) Text(stringResource(R.string.releases_no_match), style = MaterialTheme.typography.bodySmall)
            (if (showAll) filtered else filtered.take(3)).forEach { release ->
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(release.name, style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.releases_meta, release.downloadGB, release.quantization, release.createdAt.take(10)),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val entry = release.catalogEntry()
                    if (entry != null) {
                        val fitness = AndroidModelSelector.fitness(entry, profile)
                        Text(stringResource(if (fitness.canLoad) R.string.releases_available else R.string.releases_too_large),
                            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = { onSelect(entry) }, enabled = fitness.canLoad) {
                            Text(stringResource(R.string.releases_choose, entry.label))
                        }
                    } else {
                        Text(stringResource(R.string.releases_untested), style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TextButton(onClick = { uri.openUri(release.sourceUrl) }) { Text(stringResource(R.string.releases_model_card)) }
                }
            }
            if (filtered.size > 3) {
                TextButton(onClick = { showAll = !showAll }) {
                    Text(if (showAll) stringResource(R.string.releases_show_less) else stringResource(R.string.releases_show_all, filtered.size))
                }
            }
        }
        if (unavailable) Text(stringResource(R.string.releases_unavailable), style = MaterialTheme.typography.bodySmall)
        if (refreshing) CircularProgressIndicator(modifier = Modifier.padding(8.dp))
        TextButton(onClick = { scope.launch { refresh(force = true) } }, enabled = !refreshing) {
            Text(stringResource(R.string.releases_refresh))
        }
    }
}
