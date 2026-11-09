package ai.quenderin.app

import android.content.Context
import ai.quenderin.core.LocalPace

/** Remembers which built-in tools are on. Missing keys stay on, so first open changes nothing. */
internal object BuiltinToolPrefs {
    private const val prefix = "builtin."

    fun load(context: Context) {
        val prefs = context.getSharedPreferences("quenderin", Context.MODE_PRIVATE)
        for (id in LocalPace.builtinIds) {
            if (prefs.contains(prefix + id)) LocalPace.setOn(id, prefs.getBoolean(prefix + id, true))
        }
    }

    fun set(context: Context, id: String, on: Boolean) {
        LocalPace.setOn(id, on)
        context.getSharedPreferences("quenderin", Context.MODE_PRIVATE)
            .edit().putBoolean(prefix + id, on).apply()
    }
}
