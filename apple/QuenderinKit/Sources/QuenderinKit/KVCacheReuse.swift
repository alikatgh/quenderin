import Foundation

/// Decides how much of a new prompt is ALREADY in the KV cache from the prior turn, so a chat turn
/// only decodes the NEW tokens instead of re-prefilling the whole history every time — time-to-first-
/// token stays flat instead of growing with conversation length (and the SoC stops re-chewing the same
/// context). Pure + testable. Twin of Android `KVCacheReuse`; the native decode loop mirrors this spec.
///
/// ## Why "strict prefix" alone wasn't enough
/// The original plan reused the cache ONLY when it was a strict *prefix* of the new prompt (the plain
/// "append one turn" case). That works until the context budget fills and `ConversationContext` starts
/// dropping the OLDEST turn: the new prompt is then `system + [t2..tN]` while the cache holds
/// `system + [t1..t_{N-1}]`, so the tokens right after the system prompt diverge and the common prefix
/// collapses — reuse fell to zero and EVERY subsequent turn re-prefilled the whole ~n_ctx window. The
/// flat-TTFT promise inverted exactly when chats got long (see `docs/audits/2026-07-01-kv-cache-reuse-cliff.md`).
///
/// ## The context-shift plan
/// We now express the reuse as a KV **eviction range + shift**, which the native side executes with
/// llama.cpp's `llama_memory_seq_rm` (drop the evicted tokens) + `llama_memory_seq_add` (shift the
/// survivors' positions down, RoPE-corrected). Four outcomes, all via the same three fields:
///   - **append**  — cache is a strict prefix of `new`; keep everything, decode the suffix. (evict range empty)
///   - **shift**   — the front dropped but a contiguous tail still aligns; evict the dropped middle
///                   `[evictFrom, evictTo)`, shift survivors down, decode only the truly-new tail.
///   - **prefix**  — only the leading common prefix survives; keep it, drop the rest, decode `new[p:]`.
///   - **full**    — nothing usable (first turn, system prompt changed): clear and reprefill.
///
/// **Fail-safe:** the plan only ever proposes reusing a token region that is identical between cache and
/// new prompt, so it can never feed the model a corrupted context — a wrong guess costs at most a
/// re-prefill. And because `seq_rm` can refuse a partial removal on some cache types (e.g. SWA), the
/// native executor treats a shift as *best-effort* and falls back to a full reprefill if the eviction
/// fails — so this is a pure speedup with no correctness risk.
public enum KVCacheReuse {
    public struct Plan: Equatable {
        /// True ⇒ wipe the KV cache and decode the whole prompt from position 0 (the "full" case).
        public let clearCache: Bool
        /// Index into the NEW token array where decoding starts (how many leading tokens are reused).
        public let decodeFrom: Int
        /// Start (inclusive) of the KV position range to remove before shifting; == `evictTo` ⇒ no eviction.
        public let evictFrom: Int
        /// End (exclusive) of the range to remove. Survivors in `[evictTo, cacheLen)` shift DOWN by
        /// `(evictTo - evictFrom)` so the cache stays contiguous at `[0, decodeFrom)`.
        public let evictTo: Int

        public init(clearCache: Bool, decodeFrom: Int, evictFrom: Int = 0, evictTo: Int = 0) {
            self.clearCache = clearCache
            self.decodeFrom = decodeFrom
            self.evictFrom = evictFrom
            self.evictTo = evictTo
        }
    }

    /// Cap on how many dropped tokens we'll scan for a tail alignment. A dropped chat turn is normally
    /// tens–low-hundreds of tokens; beyond this we fall back to prefix-only reuse (still correct). The
    /// scan is comparison-only and runs once per turn, so this bound keeps it comfortably sub-millisecond.
    public static let maxEvictScan = 2048

    /// `cached` = the exact tokens currently in the KV cache (prior prompt + generated reply).
    /// `new` = the freshly-tokenized full prompt for this turn.
    public static func plan(cached: [Int32], new: [Int32]) -> Plan {
        let nc = cached.count
        let nn = new.count

        // Longest common prefix length.
        var p = 0
        let lim = min(nc, nn)
        while p < lim && cached[p] == new[p] { p += 1 }

        // append: a NON-EMPTY cache that is a strict prefix of the new prompt — keep all, decode the suffix.
        if nc > 0 && p == nc && nc < nn {
            return Plan(clearCache: false, decodeFrom: nc)
        }

        // The cache has tokens beyond the common prefix (front-drop / divergence / edited history).
        if p < nc {
            // shift: find the SMALLEST gap g>0 such that the cache's tail `cached[p+g ..< nc]` matches
            // `new[p ..< p+tailLen]` — a contiguous middle chunk was dropped but the rest still lines up.
            // Smallest g ⇒ largest reused tail. Bounded by `maxEvictScan`.
            let maxG = min(nc - p, maxEvictScan)
            var g = 1
            while g <= maxG {
                let tailLen = nc - p - g
                if tailLen <= 0 { break }
                // Need at least one genuinely new token left to decode (never a 0-length decode).
                if p + tailLen < nn && regionsEqual(cached, p + g, new, p, tailLen) {
                    return Plan(clearCache: false, decodeFrom: p + tailLen, evictFrom: p, evictTo: p + g)
                }
                g += 1
            }
            // prefix: no tail aligned — keep just the common prefix `[0, p)`, drop the rest, decode `new[p:]`.
            if p >= 1 && p < nn {
                return Plan(clearCache: false, decodeFrom: p, evictFrom: p, evictTo: nc)
            }
        }

        // full: nothing usable (first turn, identical/shorter prompt, or system prompt changed).
        return Plan(clearCache: true, decodeFrom: 0)
    }

    /// True iff `a[aStart ..< aStart+len] == b[bStart ..< bStart+len]`. Callers guarantee in-bounds ranges.
    private static func regionsEqual(_ a: [Int32], _ aStart: Int, _ b: [Int32], _ bStart: Int, _ len: Int) -> Bool {
        for i in 0..<len where a[aStart + i] != b[bStart + i] { return false }
        return true
    }
}
