package ai.quenderin.core

/**
 * Decides how much of a new prompt is ALREADY in the KV cache from the prior turn, so a chat turn
 * only decodes the NEW tokens instead of re-prefilling the whole history every time — time-to-first-
 * token stays flat instead of growing with conversation length (and the SoC stops re-chewing the same
 * context). Pure + testable. Twin of Swift `KVCacheReuse`; the JNI decode loop mirrors this spec.
 *
 * ## Why "strict prefix" alone wasn't enough
 * The original plan reused the cache ONLY when it was a strict *prefix* of the new prompt (the plain
 * "append one turn" case). That works until the context budget fills and [ConversationContext] starts
 * dropping the OLDEST turn: the new prompt is then `system + [t2..tN]` while the cache holds
 * `system + [t1..t_{N-1}]`, so the tokens right after the system prompt diverge and the common prefix
 * collapses — reuse fell to zero and EVERY subsequent turn re-prefilled the whole ~n_ctx window. The
 * flat-TTFT promise inverted exactly when chats got long (the case a single-shot smoke test never hits;
 * see `docs/audits/2026-07-01-kv-cache-reuse-cliff.md`).
 *
 * ## The context-shift plan
 * We now express the reuse as a KV **eviction range + shift**, which the native side executes with
 * llama.cpp's `llama_memory_seq_rm` (drop the evicted tokens) + `llama_memory_seq_add` (shift the
 * survivors' positions down, RoPE-corrected). Four outcomes, all via the same three fields:
 *   - **append**  — cache is a strict prefix of `new`; keep everything, decode the suffix. (evict range empty)
 *   - **shift**   — the front dropped but a contiguous tail of the cache still aligns with `new`; evict the
 *                   dropped middle `[evictFrom, evictTo)`, shift the survivors down, decode only the truly-new tail.
 *   - **prefix**  — only the leading common prefix survives (no tail alignment); keep it, drop the rest, decode `new[p:]`.
 *   - **full**    — nothing usable (first turn, system prompt changed): clear and reprefill.
 *
 * **Fail-safe, unchanged in spirit:** the plan only ever proposes reusing a region that is byte-for-byte
 * (token-for-token) identical between cache and new prompt, so it can never feed the model a corrupted
 * context — a wrong guess costs at most a re-prefill. And because `seq_rm` can refuse a partial removal on
 * some cache types (e.g. SWA), the native executor treats a shift as *best-effort* and falls back to a full
 * reprefill if the eviction fails — so this is a pure speedup with no correctness risk.
 */
object KVCacheReuse {
    /**
     * @param clearCache  true ⇒ the native side wipes the whole cache before decoding (the "full" case).
     *                    Kept for back-compat with the original two-field plan; false for append/shift/prefix.
     * @param decodeFrom  index into `new` where decoding starts (how many leading tokens are reused).
     * @param evictFrom   start (inclusive) of the KV position range to remove before shifting; == [evictTo] ⇒ no eviction.
     * @param evictTo     end (exclusive) of the range to remove. Survivors in `[evictTo, cacheLen)` are shifted
     *                    DOWN by `(evictTo - evictFrom)` so the cache stays contiguous at `[0, decodeFrom)`.
     */
    data class Plan(
        val clearCache: Boolean,
        val decodeFrom: Int,
        val evictFrom: Int = 0,
        val evictTo: Int = 0,
    )

    /**
     * Cap on how many dropped tokens we'll scan for a tail alignment. A dropped chat turn is normally
     * tens–low-hundreds of tokens; searching further costs more than it saves, so beyond this we fall
     * back to prefix-only reuse (still correct, just keeps only the common prefix). The scan is
     * comparison-only and runs once per turn, so this bound keeps it comfortably sub-millisecond.
     */
    const val MAX_EVICT_SCAN = 2048

    fun plan(cached: IntArray, new: IntArray): Plan {
        val nc = cached.size
        val nn = new.size

        // Longest common prefix length.
        var p = 0
        val lim = minOf(nc, nn)
        while (p < lim && cached[p] == new[p]) p++

        // append: a NON-EMPTY cache that is a strict prefix of the new prompt — keep all, decode the suffix.
        if (nc > 0 && p == nc && nc < nn) {
            return Plan(clearCache = false, decodeFrom = nc)
        }

        // The cache has tokens beyond the common prefix (front-drop / divergence / edited history).
        if (p < nc) {
            // shift: find the SMALLEST gap g>0 such that the cache's tail `cached[p+g, nc)` matches
            // `new[p, p+tailLen)` — i.e. a contiguous middle chunk was dropped but the rest still lines up.
            // Smallest g ⇒ largest reused tail. Bounded by MAX_EVICT_SCAN.
            val maxG = minOf(nc - p, MAX_EVICT_SCAN)
            var g = 1
            while (g <= maxG) {
                val tailLen = nc - p - g
                if (tailLen <= 0) break
                // Need at least one genuinely new token left to decode (never a 0-length decode).
                if (p + tailLen < nn && regionsEqual(cached, p + g, new, p, tailLen)) {
                    return Plan(clearCache = false, decodeFrom = p + tailLen, evictFrom = p, evictTo = p + g)
                }
                g++
            }
            // prefix: no tail aligned — keep just the common prefix `[0, p)`, drop the rest, decode `new[p:]`.
            // Only worthwhile when there's a real prefix AND at least one new token to decode.
            if (p in 1 until nn) {
                return Plan(clearCache = false, decodeFrom = p, evictFrom = p, evictTo = nc)
            }
        }

        // full: nothing usable (first turn, identical/shorter prompt, or system prompt changed).
        return Plan(clearCache = true, decodeFrom = 0)
    }

    /** True iff `a[aStart, aStart+len) == b[bStart, bStart+len)`. Callers guarantee the ranges are in-bounds. */
    private fun regionsEqual(a: IntArray, aStart: Int, b: IntArray, bStart: Int, len: Int): Boolean {
        for (i in 0 until len) if (a[aStart + i] != b[bStart + i]) return false
        return true
    }
}
