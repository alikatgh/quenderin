package ai.quenderin.app.ui

import ai.quenderin.app.R
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource

/**
 * Localized Settings labels for gated capabilities. The tool id (`fs.read`) stays the
 * consent-store key; this is presentation only. Twin of iOS `CapabilityCatalog.displayName`
 * + `String(localized:)` on `purpose`. Unknown ids fall back to the English purpose the
 * tool already carries, never an empty row.
 */
@Composable
internal fun capabilityTitle(name: String): String {
    val id = TITLE[name] ?: return name
    return stringResource(id)
}

@Composable
internal fun capabilityPurpose(name: String, englishFallback: String): String {
    val id = PURPOSE[name] ?: return englishFallback
    return stringResource(id)
}

private val TITLE = mapOf(
    "calculator" to R.string.cap_title_calculator,
    "units" to R.string.cap_title_units,
    "date" to R.string.cap_title_date,
    "fs.read" to R.string.cap_title_fs_read,
    "fs.list" to R.string.cap_title_fs_list,
    "fs.move" to R.string.cap_title_fs_move,
    "fs.rename" to R.string.cap_title_fs_rename,
    "fs.trash" to R.string.cap_title_fs_trash,
    "device.clipboard.read" to R.string.cap_title_clipboard,
    "device.calendar.today" to R.string.cap_title_calendar,
    "device.status" to R.string.cap_title_status,
)

private val PURPOSE = mapOf(
    "calculator" to R.string.cap_purpose_calculator,
    "units" to R.string.cap_purpose_units,
    "date" to R.string.cap_purpose_date,
    "fs.read" to R.string.cap_purpose_fs_read,
    "fs.list" to R.string.cap_purpose_fs_list,
    "fs.move" to R.string.cap_purpose_fs_move,
    "fs.rename" to R.string.cap_purpose_fs_rename,
    "fs.trash" to R.string.cap_purpose_fs_trash,
    "device.clipboard.read" to R.string.cap_purpose_clipboard,
    "device.calendar.today" to R.string.cap_purpose_calendar,
    "device.status" to R.string.cap_purpose_status,
)
