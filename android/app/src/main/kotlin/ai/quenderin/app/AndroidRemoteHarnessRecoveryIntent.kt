package ai.quenderin.app

import ai.quenderin.core.RemoteHarnessClientRecoveryIntentStore
import ai.quenderin.core.RemoteHarnessException
import android.content.Context

/** Small device-local intent, independent of the bounded transcript/draft journal.
 * Its existing preference file is excluded from cloud backup and device transfer. */
class AndroidRemoteHarnessRecoveryIntent(context: Context) : RemoteHarnessClientRecoveryIntentStore {
    private val preferences = context.getSharedPreferences("remote-presentation", Context.MODE_PRIVATE)
    @Synchronized override fun read(): Boolean = try {
        preferences.getBoolean(KEY, false)
    } catch (_: Exception) { throw RemoteHarnessException("client-recovery-intent") }

    @Synchronized override fun write(allowed: Boolean) {
        try {
            if (!preferences.edit().putBoolean(KEY, allowed).commit() || read() != allowed)
                throw RemoteHarnessException("client-recovery-intent")
        } catch (_: Exception) { throw RemoteHarnessException("client-recovery-intent") }
    }
    companion object { private const val KEY = "foregroundReconnectAllowed" }
}
