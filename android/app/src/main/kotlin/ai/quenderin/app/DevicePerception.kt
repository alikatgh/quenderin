package ai.quenderin.app

import ai.quenderin.core.ActionPreview
import ai.quenderin.core.BlastRadius
import ai.quenderin.core.Capability
import ai.quenderin.core.CapabilityTier
import android.content.ClipboardManager
import android.content.Context
import android.os.BatteryManager
import android.os.StatFs
import java.util.Locale

/**
 * T1 device PERCEPTION for the phone agent — the Android twins of the Swift
 * `DeviceCapabilities` (owner sign-off 2026-07-07; PRODUCT.md revised: mobile is T0–T1 + the
 * consented workspace). Read-only by declaration, consent-gated by the same spine; nothing
 * here writes. Calendar perception is deliberately NOT in this slice — READ_CALENDAR is a
 * store-sensitive manifest permission that deserves its own change.
 */

/** T1: read the clipboard — "use what I just copied". Same contract as device.clipboard.read
 *  on iOS (name shared so the model's learning transfers). */
class DeviceClipboardReadCapability(
    private val context: Context,
    private val maxChars: Int = 4000,
) : Capability {
    override val name = "device.clipboard.read"
    override val purpose = "Read the text currently on the clipboard. No input."
    override val tier = CapabilityTier.READ_ONLY
    override val blastRadius: BlastRadius = BlastRadius.Read("the clipboard")

    override fun plan(input: String): ActionPreview =
        ActionPreview("Would read the text currently on your clipboard (read-only).", mutates = false)

    override fun run(input: String): String {
        val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)
            ?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
        if (clip.isNullOrEmpty()) return "The clipboard is empty (or holds no text)."
        return if (clip.length > maxChars) clip.take(maxChars) + "\n[…clipboard truncated]" else clip
    }
}

/** T1: battery + free storage in one glance — same contract as device.status on iOS. */
class DeviceStatusCapability(private val context: Context) : Capability {
    override val name = "device.status"
    override val purpose = "Report the battery level and free storage of this device. No input."
    override val tier = CapabilityTier.READ_ONLY
    override val blastRadius: BlastRadius = BlastRadius.Read("battery and storage levels")

    override fun plan(input: String): ActionPreview =
        ActionPreview("Would read the battery level and free storage (read-only).", mutates = false)

    override fun run(input: String): String {
        val parts = mutableListOf<String>()
        val battery = (context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager)
            ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (battery != null && battery in 0..100) parts.add("Battery: $battery%")
        runCatching {
            val free = StatFs(context.filesDir.path).availableBytes
            // Locale.ROOT, not the default locale: this string is MODEL-FACING (device.status tool
            // output) and must match the iOS twin, whose String(format:) renders in the POSIX/C
            // locale. Default-locale "%.1f" yields "1,5" in de/fr (or Eastern-Arabic digits in ar) —
            // the exact cross-platform number drift the seam-normalization series just eliminated in
            // core. Twin: iOS DeviceStatusCapability.
            parts.add("Free storage: ${String.format(Locale.ROOT, "%.1f", free / 1_000_000_000.0)} GB")
        }
        return if (parts.isEmpty()) "Couldn't read the device status here." else parts.joinToString(" · ")
    }
}

/** The phone's perception set — grows like every other library; the spine stays fixed. */
fun devicePerceptionCapabilities(context: Context): List<Capability> = listOf(
    DeviceClipboardReadCapability(context),
    DeviceStatusCapability(context),
)
