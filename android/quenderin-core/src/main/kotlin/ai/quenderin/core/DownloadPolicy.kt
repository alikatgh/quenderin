package ai.quenderin.core

enum class NetworkStatus { WIFI, CELLULAR, NONE }

/**
 * Whether a large model download may proceed on the current connection. A multi-GB pull
 * on cellular can cost real money and stall — default to Wi-Fi-only, never start with no
 * connection. Pure decision layer (tested); the live status comes from the app via
 * `ConnectivityManager`. Mirrors iOS `DownloadPolicy`.
 */
enum class DownloadPolicy {
    WIFI_ONLY,
    WIFI_OR_CELLULAR;

    fun allows(status: NetworkStatus): Boolean = when {
        status == NetworkStatus.NONE -> false
        this == WIFI_ONLY && status == NetworkStatus.CELLULAR -> false
        else -> true
    }

    /** Why a download is being held back, in the user's words — or null if allowed. */
    fun reason(status: NetworkStatus): String? {
        if (allows(status)) return null
        return when (status) {
            NetworkStatus.NONE ->
                "No internet connection. Connect to Wi-Fi to download your model before going offline."
            NetworkStatus.CELLULAR ->
                "You're on cellular. This model is large — connect to Wi-Fi, or allow cellular downloads in settings."
            NetworkStatus.WIFI -> null
        }
    }
}
