package ai.quenderin.core

import java.net.URI

/** Assistant-provided links never receive authority to launch arbitrary app intents. */
object MarkdownLinkPolicy {
    fun allows(destination: String): Boolean {
        if (destination.isEmpty() || destination.length > 8_192 || destination.any { it.isWhitespace() || it.code < 32 || it.code == 127 } ||
            Regex("%(?:00|0a|0d)", RegexOption.IGNORE_CASE).containsMatchIn(destination)) return false
        val uri = try { URI(destination) } catch (_: Exception) { return false }
        return when (uri.scheme?.lowercase(java.util.Locale.ROOT)) {
            "http", "https" -> !uri.isOpaque && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null
            "mailto" -> uri.isOpaque && uri.rawSchemeSpecificPart.isNotEmpty() && uri.rawFragment == null
            else -> false
        }
    }
}
