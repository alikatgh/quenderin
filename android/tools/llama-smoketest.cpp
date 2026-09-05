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

    // --ttft mode: `llama-smoketest <model> --ttft cold|warm [nGpuLayers]` — a FRESH PROCESS measures the
    // first message's time-to-first-token on a fresh context, with or without warmupContext() first.
    // Only a fresh process is honest here: in-process, an earlier decode has already paged the weights
    // in and initialized the kernels. scripts/bench_inference.sh runs this both ways and reports both.
    if (userText == "--ttft") {
        const bool warm = argc >= 4 && std::string(argv[3]) == "warm";
        nGpuLayers = argc >= 5 ? atoi(argv[4]) : nGpuLayers;
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = 2048;
        llama_context* c = llama_init_from_model(model, cp);
        if (!c) { printf("FAIL: context (ttft)\n"); return 1; }
        llama_sampler* g = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(g, llama_sampler_init_greedy());
        double warmupMs = 0;
        if (warm) {
            const auto w0 = std::chrono::steady_clock::now();
            quenderin::warmupContext(c, vocab);
            warmupMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - w0).count();
        }
        std::vector<llama_token> tiny = tokenize(vocab, userTurn("Why is the sky blue?"), true);
        std::vector<llama_token> cache;
        const auto t0 = std::chrono::steady_clock::now();
        std::string first = quenderin::generateWithKVReuse(c, vocab, g, tiny, 1, cache, noEmit, noCancel);
        const double ttftMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        printf("TTFT: %s %zu-tok prompt → first token in %.0f ms (warmup cost %.0f ms, off the critical path)\n",
               warm ? "warm" : "cold", tiny.size(), ttftMs, warmupMs);
        llama_sampler_free(g);
        llama_free(c);
        llama_model_free(model);
        llama_backend_free();
        return first.empty() ? 1 : 0;
    }

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

    llama_free(ctxA);
    llama_free(ctxB);

    // --- Part 3: prefill longer than n_batch must NOT abort the process (and must decode the same as
    // one big batch). llama.cpp GGML_ASSERTs n_tokens <= n_batch per llama_decode call; the JNI sizes
    // n_batch to min(512, n_ctx), so a document attachment / restored long chat used to SIGABRT the app.
    // A tiny n_batch (32) forces the chunked path on the 256+-token bench prompt; n_batch=2048 on a twin
    // context is the single-call ground truth. Greedy ⇒ byte-identical output is the pass condition. ---
    {
        llama_context_params small = llama_context_default_params();
        small.n_ctx = 2048; small.n_batch = 32; small.n_ubatch = 32;
        llama_context_params big = llama_context_default_params();
        big.n_ctx = 2048; big.n_batch = 2048; big.n_ubatch = 512;
        llama_context* ctxS = llama_init_from_model(model, small);
        llama_context* ctxL = llama_init_from_model(model, big);
        if (!ctxS || !ctxL) { printf("FAIL: context (chunked prefill)\n"); return 1; }
        std::vector<llama_token> cs, cl;
        std::string outS = quenderin::generateWithKVReuse(ctxS, vocab, smpl, promptTokens, 16, cs, noEmit, noCancel);
        std::string outL = quenderin::generateWithKVReuse(ctxL, vocab, smpl, promptTokens, 16, cl, noEmit, noCancel);
        if (outS == outL && !outS.empty()) {
            printf("PASS: chunked prefill (%zu tok through n_batch=32) matches single-batch decode\n",
                   promptTokens.size());
        } else {
            printf("FAIL: chunked prefill output differs from single-batch\n  chunked: %s\n  single:  %s\n",
                   outS.c_str(), outL.c_str());
            rc = 1;
        }
        // Middle-out clamp: a prompt far past n_ctx must degrade to a bounded prefill, not rc=1 forever.
        std::vector<llama_token> huge;
        for (int i = 0; i < 12; ++i) huge.insert(huge.end(), promptTokens.begin(), promptTokens.end());
        bool failed = false;
        std::vector<llama_token> ch;
        std::string outH = quenderin::generateWithKVReuse(ctxS, vocab, smpl, huge, 16, ch, noEmit, noCancel, &failed);
        if (!failed && !ch.empty() && ch.size() <= 2048) {
            printf("PASS: over-length prompt (%zu tok) clamped to %zu and decoded\n", huge.size(), ch.size() - 16);
        } else {
            printf("FAIL: over-length prompt (%zu tok) failed=%d cached=%zu\n", huge.size(), (int) failed, ch.size());
            rc = 1;
        }
        llama_free(ctxS);
        llama_free(ctxL);
    }

    // --- Part 4: warmup — the first prefill on a fresh context pays weight page-in + kernel init.
    // Report the 12-token time-to-first-token cold vs after warmupContext(); informational (SLO input
    // for docs/INFERENCE_SLO.md), never a pass/fail — it depends on the box's load and page cache. ---
    {
        std::vector<llama_token> tiny = tokenize(vocab, userTurn("Why is the sky blue?"), true);
        auto ttft = [&](llama_context* c) {
            std::vector<llama_token> cache;
            const auto t0 = std::chrono::steady_clock::now();
            std::string one = quenderin::generateWithKVReuse(c, vocab, smpl, tiny, 1, cache, noEmit, noCancel);
            return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        };
        llama_context* cold = makeCtx();
        llama_context* warm = makeCtx();
        if (!cold || !warm) { printf("FAIL: context (warmup)\n"); return 1; }
        const double coldMs = ttft(cold);
        const auto w0 = std::chrono::steady_clock::now();
        quenderin::warmupContext(warm, vocab);
        const double warmupMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - w0).count();
        const double warmMs = ttft(warm);
        printf("WARMUP: first-token latency %zu-tok prompt: cold %.0f ms | warmup cost %.0f ms then %.0f ms\n",
               tiny.size(), coldMs, warmupMs, warmMs);
        llama_free(cold);
        llama_free(warm);
    }

    llama_sampler_free(smpl);
    llama_model_free(model);
    llama_backend_free();
    return rc;
}
