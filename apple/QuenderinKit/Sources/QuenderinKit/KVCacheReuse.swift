import Foundation

/// Decides how much of a new prompt is ALREADY in the KV cache from the prior turn, so a chat turn
/// only decodes the NEW tokens instead of re-prefilling the whole history every time. That's the
/// difference between time-to-first-token staying flat vs. growing with conversation length (and the
/// SoC heating up re-chewing the same context). Pure + testable. Twin of Android `KVCacheReuse`.
///
/// **Fail-safe:** reuse ONLY when the cache is a strict prefix of the new prompt — the common
/// "append one turn" case. Any divergence (the context window slid and evicted old turns, history was
/// edited, a new conversation) → wipe the cache and prefill from scratch. So a mismatch costs a
/// re-prefill (correct, just no speedup); it can never feed the model a corrupted context.
public enum KVCacheReuse {
    public struct Plan: Equatable {
        /// True ⇒ wipe the KV cache and decode the whole prompt from position 0.
        public let clearCache: Bool
        /// Index into the NEW token array where decoding should start (0 when clearing).
        public let decodeFrom: Int
        public init(clearCache: Bool, decodeFrom: Int) {
            self.clearCache = clearCache
            self.decodeFrom = decodeFrom
        }
    }

    /// `cached` = the exact tokens currently in the KV cache (prior prompt + generated reply).
    /// `new` = the freshly-tokenized full prompt for this turn.
    public static func plan(cached: [Int32], new: [Int32]) -> Plan {
        if !cached.isEmpty, cached.count < new.count, new.prefix(cached.count).elementsEqual(cached) {
            return Plan(clearCache: false, decodeFrom: cached.count)   // pure append: keep KV, decode only the suffix
        }
        return Plan(clearCache: true, decodeFrom: 0)                   // diverged / first turn: full reprefill
    }
}
