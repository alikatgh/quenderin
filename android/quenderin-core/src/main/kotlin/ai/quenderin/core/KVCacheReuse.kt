package ai.quenderin.core

/**
 * Decides how much of a new prompt is ALREADY in the KV cache from the prior turn, so a chat turn
 * only decodes the NEW tokens instead of re-prefilling the whole history every time — time-to-first-
 * token stays flat instead of growing with conversation length (and the SoC stops re-chewing the same
 * context). Pure + testable. Twin of Swift `KVCacheReuse`; the JNI decode loop mirrors this spec.
 *
 * **Fail-safe:** reuse ONLY when the cache is a strict prefix of the new prompt (the common
 * "append one turn" case). Any divergence → wipe the cache and reprefill from scratch, so a mismatch
 * costs a re-prefill (correct, just no speedup); it can never feed the model a corrupted context.
 */
object KVCacheReuse {
    data class Plan(val clearCache: Boolean, val decodeFrom: Int)

    fun plan(cached: IntArray, new: IntArray): Plan {
        if (cached.isNotEmpty() && cached.size < new.size) {
            var isPrefix = true
            for (i in cached.indices) {
                if (cached[i] != new[i]) { isPrefix = false; break }
            }
            if (isPrefix) return Plan(clearCache = false, decodeFrom = cached.size) // pure append
        }
        return Plan(clearCache = true, decodeFrom = 0)                              // diverged / first turn
    }
}
