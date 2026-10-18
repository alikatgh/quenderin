package ai.quenderin.core

import java.io.File

/** Available whole-system RAM for large manual models; failure never means unlimited memory. */
internal object NativeModelResources {
    fun availableMemoryBytes(): Long = runCatching {
        File("/proc/meminfo").inputStream().use { stream ->
            val buffer = ByteArray(16 * 1024)
            val count = stream.read(buffer)
            if (count <= 0) return@use 0L
            val line = String(buffer, 0, count, Charsets.US_ASCII).lineSequence().firstOrNull { it.startsWith("MemAvailable:") }
                ?: return@use 0L
            val kib = Regex("^MemAvailable:\\s+(\\d+)\\s+kB$").matchEntire(line)?.groupValues?.get(1)?.toLongOrNull()
                ?: return@use 0L
            if (kib < 0 || kib > Long.MAX_VALUE / 1024) 0L else kib * 1024
        }
    }.getOrDefault(0L)
}
