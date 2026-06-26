// Standalone C++ proof that llama.cpp inference runs on Android (arm64). Mirrors the
// VERIFIED iOS apple/tools/llama-smoketest.swift, using the same llama.cpp C API the JNI
// bridge (jni/llama_jni.cpp) calls. Built + run on an emulator/device by
// android/verify-llama-link.sh.
//
//   usage: llama-smoketest <model.gguf> [prompt] [maxTokens]
//
// CPU by default (Android GPU offload via Vulkan/OpenCL is a later tuning step).
//
// It drives generation through the SHARED loop in jni/llama_generate.h — the exact code the JNI
// bridge ships — so this on-device run actually exercises the production decode path (the JNI's own
// generate() has no other on-device coverage). Part 2 is a multi-turn KV-reuse equivalence check:
// a regression guard for the KV-mirror desync bug (docs/BUG_JOURNAL.md). Non-zero exit on any failure.
#include "llama.h"
#include "../jni/llama_generate.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& text, bool add_bos) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, add_bos, true);
    if (n <= 0) return {};
    std::vector<llama_token> tokens(n);
    llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, add_bos, true);
    return tokens;
}

// Chat-template a single user turn (matches the JNI/iOS prompt shape closely enough for the proof).
std::string userTurn(const std::string& text) {
    return "<|im_start|>user\n" + text + "<|im_end|>\n<|im_start|>assistant\n";
}

auto noEmit    = [](const std::string&) { return true; };
auto noCancel  = []() { return false; };

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: llama-smoketest <model.gguf> [prompt] [maxTokens] [nGpuLayers]\n"); return 2; }
    const char* modelPath = argv[1];
    std::string userText = argc >= 3 ? argv[2] : "Write three sentences about why the sky is blue.";
    int maxTokens = argc >= 4 ? atoi(argv[3]) : 96;
    // 4th arg = n_gpu_layers, so a real device can A/B CPU (0) vs Vulkan GPU offload (999). Needs a .so
    // built with -DGGML_VULKAN=ON to have any effect; on a CPU-only build a positive value is a no-op.
    int nGpuLayers = argc >= 5 ? atoi(argv[4]) : 0;

    llama_backend_init();
    printf("MODE: %s (n_gpu_layers=%d, gpu_offload_supported=%s)\n",
           nGpuLayers > 0 ? "GPU-offload" : "CPU", nGpuLayers,
           llama_supports_gpu_offload() ? "yes" : "no");

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = nGpuLayers;
    llama_model* model = llama_model_load_from_file(modelPath, mp);
    if (!model) { printf("FAIL: model load\n"); return 1; }
    const llama_vocab* vocab = llama_model_get_vocab(model);

    auto makeCtx = [&]() -> llama_context* {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = 2048;
        return llama_init_from_model(model, cp);
    };

    // Greedy is stateless (argmax), so one sampler is safe across contexts — and greedy makes the
    // multi-turn equivalence check below deterministic.
    llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    // --- Part 1: PREFILL vs DECODE throughput, measured SEPARATELY. This is the whole point of a GPU
    // A/B: the offload signal lives in PREFILL (compute-bound, parallel — GPU should win), while DECODE
    // is memory-bandwidth bound and barely moves (CPU and GPU share the RAM bus). Reporting one blended
    // number would hide exactly the thing you're trying to measure. A long prompt makes prefill
    // meaningful — a 12-token prompt is noise, so pad to >= 256 tokens with neutral filler. ---
    llama_context* ctx = makeCtx();
    if (!ctx) { printf("FAIL: context\n"); return 1; }

    std::string benchText = userText;
    const std::string filler = " The sky appears blue because shorter wavelengths scatter more.";
    std::vector<llama_token> promptTokens = tokenize(vocab, userTurn(benchText), true);
    while ((int) promptTokens.size() < 256) {
        benchText += filler;
        promptTokens = tokenize(vocab, userTurn(benchText), true);
    }

    // Prefill: decode the entire prompt in one batch, timed on its own.
    auto pf0 = std::chrono::steady_clock::now();
    {
        llama_batch pf = llama_batch_get_one(promptTokens.data(), (int32_t) promptTokens.size());
        if (llama_decode(ctx, pf) != 0) { printf("FAIL: prefill decode\n"); return 1; }
    }
    double prefillSec = std::chrono::duration<double>(std::chrono::steady_clock::now() - pf0).count();

    // Decode: generate maxTokens, timed on its own (sample → feed back → repeat).
    std::string out;
    int gen = 0;
    auto dc0 = std::chrono::steady_clock::now();
    for (int i = 0; i < maxTokens; ++i) {
        llama_token next = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, next)) break;
        char buf[256];
        int c = llama_token_to_piece(vocab, next, buf, sizeof(buf), 0, true);
        if (c > 0) out.append(buf, c);
        gen++;
        llama_batch one = llama_batch_get_one(&next, 1);
        if (llama_decode(ctx, one) != 0) break;
    }
    double decodeSec = std::chrono::duration<double>(std::chrono::steady_clock::now() - dc0).count();

    printf("ANSWER: %s\n", out.c_str());
    printf("REAL: prefill %zu tok in %.3fs = %.1f tok/s | decode %d tok in %.2fs = %.1f tok/s [%s]\n",
           promptTokens.size(), prefillSec, promptTokens.size() / (prefillSec > 0 ? prefillSec : 1e-6),
           gen, decodeSec, gen / (decodeSec > 0 ? decodeSec : 1e-6), nGpuLayers > 0 ? "GPU" : "CPU");
    llama_free(ctx);

    // --- Part 2: multi-turn KV-reuse equivalence (regression guard for the KV-mirror desync). ---
    // Build turn 2 by APPENDING new tokens to the post-turn-1 cache, so the reuse path is GUARANTEED
    // exercised (cache is a strict prefix). The same turn-2 prompt is then full-prefilled on a fresh
    // context. With greedy decoding the two outputs MUST be byte-identical; if the mirror ever ran
    // ahead of the KV (the bug), the reuse path would decode at the wrong positions and diverge.
    llama_context* ctxA = makeCtx();   // persistent: turn 1, then turn 2 via KV reuse
    llama_context* ctxB = makeCtx();   // fresh: turn 2 via full prefill (ground truth)
    if (!ctxA || !ctxB) { printf("FAIL: context (equivalence)\n"); return 1; }

    std::vector<llama_token> cachedA, cachedB;
    std::vector<llama_token> q1 = tokenize(vocab, userTurn("Name one primary color."), true);
    std::string r1 = quenderin::generateWithKVReuse(ctxA, vocab, smpl, q1, 24, cachedA, noEmit, noCancel);

    // turn-2 tokens = the exact KV contents after turn 1 ++ a new user turn (no re-BOS).
    std::vector<llama_token> suffix =
        tokenize(vocab, "<|im_end|>\n" + userTurn("Name a different one."), /*add_bos*/ false);
    std::vector<llama_token> q2 = cachedA;
    q2.insert(q2.end(), suffix.begin(), suffix.end());

    std::string a2Reuse = quenderin::generateWithKVReuse(ctxA, vocab, smpl, q2, 24, cachedA, noEmit, noCancel);
    std::string a2Fresh = quenderin::generateWithKVReuse(ctxB, vocab, smpl, q2, 24, cachedB, noEmit, noCancel);

    int rc = 0;
    if (a2Reuse == a2Fresh) {
        printf("PASS: KV-reuse turn-2 output identical to full prefill (%zu prompt tokens, %zu reused)\n",
               q2.size(), q2.size() - suffix.size());
    } else {
        printf("FAIL: KV-reuse desync — turn-2 reuse output differs from full prefill\n");
        printf("  reuse: %s\n  fresh: %s\n", a2Reuse.c_str(), a2Fresh.c_str());
        rc = 1;
    }

    llama_sampler_free(smpl);
    llama_free(ctxA);
    llama_free(ctxB);
    llama_model_free(model);
    llama_backend_free();
    return rc;
}
