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

// How many leading tokens of `newTokens` are ALREADY resident in the KV cache, given `cached` is the
// exact token sequence the cache holds. Reuse only on a strict-prefix extension (the common "append a
// turn" case); any divergence ⇒ 0 (full reprefill). Mirrors the tested KVCacheReuse spec (Swift/Kotlin
// twins) — strict `cached.size() < newTokens.size()` so an identical prompt reprefills, never a 0-length
// decode.
inline size_t kvReuseCount(const std::vector<llama_token>& cached,
                           const std::vector<llama_token>& newTokens) {
    if (!cached.empty() && cached.size() < newTokens.size()) {
        for (size_t i = 0; i < cached.size(); ++i) {
            if (cached[i] != newTokens[i]) return 0;
        }
        return cached.size();
    }
    return 0;
}

// Decode `newTokens` — reusing the KV from a prior turn when it's a strict-prefix extension — then
// sample up to `maxTokens`, feeding each sampled token back. Keeps `cached` in STRICT lockstep with the
// KV: the mirror is assigned only AFTER the prefill decode succeeds, and each sampled token is recorded
// only AFTER its own decode returns 0 (decode-then-record). On ANY decode failure the KV + mirror are
// cleared so the next turn does a clean full reprefill — `cached` can never claim a token the KV lacks.
//
//   emit(piece)  → return false to stop early (e.g. a pending JNI exception). Called for every piece.
//   cancelled()  → return true to stop before sampling the next token.
//
// Returns the concatenated output. `cached` is updated in place to match the KV on return.
template <typename Emit, typename Cancelled>
std::string generateWithKVReuse(llama_context* ctx, const llama_vocab* vocab, llama_sampler* sampler,
                                const std::vector<llama_token>& newTokens, int maxTokens,
                                std::vector<llama_token>& cached, Emit emit, Cancelled cancelled) {
    std::string out;
    if (newTokens.empty()) return out;

    const size_t reuse = kvReuseCount(cached, newTokens);
    if (reuse == 0) {
        llama_memory_clear(llama_get_memory(ctx), true);
    }

    // Prefill: decode the new (suffix) tokens. Keep `toDecode` alive across the decode —
    // llama_batch_get_one only borrows its pointer. Assign the mirror only on success.
    std::vector<llama_token> toDecode(newTokens.begin() + reuse, newTokens.end());
    {
        llama_batch prefill = llama_batch_get_one(toDecode.data(), (int32_t) toDecode.size());
        if (llama_decode(ctx, prefill) != 0) {
            llama_memory_clear(llama_get_memory(ctx), true);
            cached.clear();
            return out;   // empty — surfaced as a failed generation
        }
    }
    cached = newTokens;   // the KV now holds exactly newTokens

    for (int i = 0; i < maxTokens; ++i) {
        if (cancelled()) break;
        llama_token next = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, next)) break;

        char buf[256];
        int c = llama_token_to_piece(vocab, next, buf, sizeof(buf), 0, true);
        if (c > 0) {
            std::string piece(buf, c);
            out += piece;
            if (!emit(piece)) break;
        }

        // Feed the token back to extend the KV. Decode BEFORE recording it in the mirror, and push only
        // on success — so the mirror never runs ahead of the KV (an off-by-one here desyncs reuse).
        llama_batch one = llama_batch_get_one(&next, 1);
        if (llama_decode(ctx, one) != 0) break;
        cached.push_back(next);
    }
    return out;
}

} // namespace quenderin
