// Shared KV-cache-reuse generation loop for the Android native side.
//
// WHY THIS HEADER EXISTS: the JNI bridge (llama_jni.cpp) and the on-device smoke test
// (tools/llama-smoketest.cpp) used to carry SEPARATE generation loops. A KV-mirror desync was
// fixed in the JNI loop that the smoke test could never have caught — because it ran different
// code (see docs/BUG_JOURNAL.md, "Android KV-mirror desync"). Both now call the ONE loop below,
// so the smoke test exercises the exact shipped code on a real device, and its multi-turn
// equivalence check is a true regression guard for this whole bug class.
//
// Twin of apple/.../LlamaEngine.swift's runGeneration. Keep the two in lockstep; when you change
// one, diff the other (the kotlinc core check never compiles this C++).
#pragma once

#include "llama.h"
#include <string>
#include <vector>

namespace quenderin {

// The KV-reuse decision for a new prompt, given `cached` is the exact token sequence the cache holds.
// Mirrors the tested KVCacheReuse spec (Swift/Kotlin twins — see KVCacheReuse.kt for the full rationale).
// Four outcomes, all via the same fields:
//   - append  → clearCache=false, evict range empty, decodeFrom = cached.size (strict-prefix extension).
//   - shift   → clearCache=false, evict [evictFrom, evictTo); the executor removes that middle chunk and
//               shifts the survivors down so the cache stays contiguous — the front-drop case that used to
//               force a full reprefill of the whole window every turn.
//   - prefix  → clearCache=false, evict [p, cache.size); keep only the common prefix, decode the rest.
//   - full    → clearCache=true; nothing usable, reprefill from scratch.
// The reused region is always token-for-token identical to the new prompt, so it can never corrupt context.
struct KVReusePlan {
    bool   clearCache;   // full reprefill
    size_t decodeFrom;   // index into newTokens where decoding starts (== reused token count)
    size_t evictFrom;    // KV positions [evictFrom, evictTo) to remove before shifting; == evictTo ⇒ none
    size_t evictTo;
};

// Cap on how many dropped tokens we scan for a tail realignment (mirrors KVCacheReuse.MAX_EVICT_SCAN).
inline constexpr size_t kKVMaxEvictScan = 2048;

inline KVReusePlan kvReusePlan(const std::vector<llama_token>& cached,
                               const std::vector<llama_token>& newTokens) {
    const size_t nc = cached.size();
    const size_t nn = newTokens.size();

    size_t p = 0;                                   // longest common prefix length
    const size_t lim = nc < nn ? nc : nn;
    while (p < lim && cached[p] == newTokens[p]) p++;

    // append: a non-empty cache that is a strict prefix of the new prompt.
    if (nc > 0 && p == nc && nc < nn) return {false, nc, 0, 0};

    if (p < nc) {
        // shift: smallest gap g>0 s.t. cached[p+g, nc) == newTokens[p, p+tailLen) — a dropped middle chunk.
        const size_t maxG = (nc - p) < kKVMaxEvictScan ? (nc - p) : kKVMaxEvictScan;
        for (size_t g = 1; g <= maxG; ++g) {
            const size_t tailLen = nc - p - g;
            if (tailLen == 0) break;
            if (p + tailLen < nn) {                 // ≥1 genuinely new token to decode
                bool eq = true;
                for (size_t i = 0; i < tailLen; ++i) {
                    if (cached[p + g + i] != newTokens[p + i]) { eq = false; break; }
                }
                if (eq) return {false, p + tailLen, p, p + g};
            }
        }
        // prefix-only: keep the common prefix, drop the rest.
        if (p >= 1 && p < nn) return {false, p, p, nc};
    }

    return {true, 0, 0, 0};                          // full reprefill
}

// Decode `newTokens` — reusing the KV from a prior turn when it's a strict-prefix extension — then
// sample up to `maxTokens`, feeding each sampled token back. Keeps `cached` in STRICT lockstep with the
// KV: the mirror is assigned only AFTER the prefill decode succeeds, and each sampled token is recorded
// only AFTER its own decode returns 0 (decode-then-record). On a FATAL decode failure the KV + mirror
// are cleared so the next turn does a clean full reprefill — `cached` can never claim a token the KV lacks.
//
// llama_decode return codes: 0 = ok, 1 = no free KV slot (cache full — recoverable), negative = fatal.
// Treating 1 as fatal (the original bug here) silently blanks or truncates replies the moment a long
// chat fills the context — exactly the case a single-shot smoke test can never exercise. This version:
//   - prefill code 1 with reuse in play  → drop reuse, reprefill the FULL prompt from a clean cache once
//     (usually succeeds, since n_ctx is sized to hold at least one full turn).
//   - prefill still failing after that, or any negative code → genuinely fatal; `*failed = true`.
//   - mid-generation code 1              → the context filled DURING this reply; stop and return what
//     was generated so far (like hitting maxTokens/EOG) — not a failure, partial output is still useful.
//   - mid-generation negative code with NOTHING generated yet → `*failed = true` (indistinguishable from
//     "the model said nothing" otherwise); with partial output already produced, just return it.
//
//   emit(piece)  → return false to stop early (e.g. a pending JNI exception). Called for every piece.
//   cancelled()  → return true to stop before sampling the next token.
//   thermalPoll()→ sampled every 32 tokens (heat moves slowly; the read is cheap). Returns the thread
//                  count to apply via llama_set_n_threads, or <= 0 for "no change". Mirrors iOS's
//                  in-flight ThermalGovernor (LlamaEngine.swift:248-260) — was previously wired at load
//                  time only (see llama_jni.cpp nativeLoad), never re-sampled mid-generation. Defaults
//                  to a no-op lambda for existing callers (e.g. the smoke test) that don't thermal-govern.
//   failed       → optional out-param; if set, *failed is true only on a genuine, unrecoverable failure
//                  (never on a graceful context-limit stop), so the caller can surface a real error
//                  instead of silently showing an empty reply. Defaults to nullptr for existing callers
//                  (e.g. the smoke test) that don't need the distinction.
//
// Returns the concatenated output. `cached` is updated in place to match the KV on return.
template <typename Emit, typename Cancelled, typename ThermalPoll = int(*)()>
std::string generateWithKVReuse(llama_context* ctx, const llama_vocab* vocab, llama_sampler* sampler,
                                const std::vector<llama_token>& newTokens, int maxTokens,
                                std::vector<llama_token>& cached, Emit emit, Cancelled cancelled,
                                bool* failed = nullptr,
                                ThermalPoll thermalPoll = []() -> int { return 0; }) {
    std::string out;
    if (failed) *failed = false;
    if (newTokens.empty()) return out;

    llama_memory_t mem = llama_get_memory(ctx);
    const KVReusePlan plan = kvReusePlan(cached, newTokens);
    size_t reuse = plan.decodeFrom;

    if (plan.clearCache) {
        llama_memory_clear(mem, true);
        reuse = 0;
    } else if (plan.evictFrom < plan.evictTo) {
        // Context-shift: physically drop the evicted middle [evictFrom, evictTo) from the KV, then shift
        // the survivors' positions DOWN by (evictTo-evictFrom) so the cache stays contiguous at
        // [0, decodeFrom). seq_add is RoPE-corrected. seq_rm returns false when a cache type can't do a
        // partial removal (e.g. SWA) — fall back to a clean full reprefill so correctness never depends
        // on the shift succeeding. (Append case: evictFrom==evictTo → nothing to evict, reuse==cache.size.)
        const llama_pos from = (llama_pos) plan.evictFrom;
        const llama_pos to   = (llama_pos) plan.evictTo;
        if (llama_memory_seq_rm(mem, 0, from, to)) {
            llama_memory_seq_add(mem, 0, to, -1, -(to - from));   // shift [to, ∞) down to close the gap
        } else {
            llama_memory_clear(mem, true);
            reuse = 0;
        }
    }

    // Prefill: decode the new (suffix) tokens. Keep `toDecode` alive across the decode —
    // llama_batch_get_one only borrows its pointer. Assign the mirror only on success.
    std::vector<llama_token> toDecode(newTokens.begin() + reuse, newTokens.end());
    int rc;
    {
        llama_batch prefill = llama_batch_get_one(toDecode.data(), (int32_t) toDecode.size());
        rc = llama_decode(ctx, prefill);
    }
    if (rc == 1 && reuse > 0) {
        // Cache full with the reused prefix in play — drop reuse and reprefill the whole turn fresh.
        llama_memory_clear(llama_get_memory(ctx), true);
        cached.clear();
        std::vector<llama_token> full = newTokens;
        llama_batch retry = llama_batch_get_one(full.data(), (int32_t) full.size());
        rc = llama_decode(ctx, retry);
    }
    if (rc != 0) {
        llama_memory_clear(llama_get_memory(ctx), true);
        cached.clear();
        if (failed) *failed = true;   // genuinely fatal, or even a fresh full reprefill doesn't fit n_ctx
        return out;
    }
    cached = newTokens;   // the KV now holds exactly newTokens

    constexpr int kThermalSampleInterval = 32;   // heat moves slowly; matches iOS's sample cadence
    for (int i = 0; i < maxTokens; ++i) {
        if (cancelled()) break;
        if (i % kThermalSampleInterval == 0) {
            int retuned = thermalPoll();
            if (retuned > 0) llama_set_n_threads(ctx, retuned, retuned);
        }
        llama_token next = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, next)) break;

        char buf[256];
        int c = llama_token_to_piece(vocab, next, buf, sizeof(buf), 0, true);
        if (c < 0) {
            // Piece longer than the stack buffer (rare) — llama_token_to_piece returns -(needed); the
            // original fixed-256 buffer silently dropped these. Re-run sized exactly (mirrors iOS).
            std::vector<char> big(-c);
            c = llama_token_to_piece(vocab, next, big.data(), (int32_t) big.size(), 0, true);
            if (c > 0) {
                std::string piece(big.data(), (size_t) c);
                out += piece;
                if (!emit(piece)) break;
            }
        } else if (c > 0) {
            std::string piece(buf, (size_t) c);
            out += piece;
            if (!emit(piece)) break;
        }

        // Feed the token back to extend the KV. Decode BEFORE recording it in the mirror, and push only
        // on success — so the mirror never runs ahead of the KV (an off-by-one here desyncs reuse).
        llama_batch one = llama_batch_get_one(&next, 1);
        int frc = llama_decode(ctx, one);
        if (frc != 0) {
            // Code 1 mid-stream = context filled while generating THIS reply — graceful stop, not a
            // failure. A fatal (negative) code with nothing generated yet IS a failure; with partial
            // output already produced, keep it rather than discard a real (if truncated) reply.
            if (failed && out.empty() && frc != 1) *failed = true;
            break;
        }
        cached.push_back(next);
    }
    return out;
}

} // namespace quenderin
