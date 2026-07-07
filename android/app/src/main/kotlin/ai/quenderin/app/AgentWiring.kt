package ai.quenderin.app

import ai.quenderin.core.ConsentStore
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File

/**
 * App-layer glue for the governed agent — the pieces the framework-free core declares as seams.
 * Twin of the iOS wiring (UserDefaultsConsentStore + the attach flow's security-scoped copies).
 */

/** SharedPreferences-backed consent — the persistent twin of iOS `UserDefaultsConsentStore`.
 *  Granted BY THE USER via a visible switch; never auto-granted by code the model can reach. */
class PrefsConsentStore(context: Context) : ConsentStore {
    private val prefs = context.getSharedPreferences("quenderin.consent", Context.MODE_PRIVATE)
    override fun isGranted(capabilityId: String): Boolean = prefs.getBoolean(capabilityId, false)
    override fun setGranted(capabilityId: String, granted: Boolean) {
        prefs.edit().putBoolean(capabilityId, granted).apply()
    }
}

/**
 * Copy a user-picked document (SAF content:// URI) into the app's cache as a plain [File] —
 * the shape the core's `FileReadCapability` granted-map wants. Copying AT PICK TIME is the
 * Android twin of iOS "extraction at attach time": what the agent can read is fixed by the
 * user's gesture, and no SAF permission has to outlive the pick. Size-capped: fs.read only
 * ever reads 64 KB, so a multi-MB pick is truncated here rather than copied whole.
 * Returns display-name → file, or null when the source can't be read.
 */
fun copyAttachmentToCache(context: Context, uri: Uri, maxBytes: Long = 256L * 1024): Pair<String, File>? {
    val name = queryDisplayName(context, uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: "attachment.txt"
    return runCatching {
        val dir = File(context.cacheDir, "agent-attachments").apply { mkdirs() }
        // A name collision gets a numeric suffix, mirroring the iOS AttachedFilesStore.
        var dest = File(dir, name)
        var counter = 2
        while (dest.exists()) {
            val dot = name.lastIndexOf('.')
            val stem = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            dest = File(dir, "$stem ($counter)$ext")
            counter++
        }
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "unreadable document" }
            dest.outputStream().use { out ->
                val buf = ByteArray(8 * 1024)
                var total = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    val take = minOf(n.toLong(), maxBytes - total).toInt()
                    if (take > 0) out.write(buf, 0, take)
                    total += n
                    if (total >= maxBytes) break
                }
            }
        }
        dest.name to dest
    }.getOrNull()
}

private fun queryDisplayName(context: Context, uri: Uri): String? = runCatching {
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { c: Cursor -> if (c.moveToFirst()) c.getString(0) else null }
}.getOrNull()
