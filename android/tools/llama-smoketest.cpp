// Standalone C++ proof that llama.cpp inference runs on Android (arm64). Mirrors the
// VERIFIED iOS apple/tools/llama-smoketest.swift, using the same llama.cpp C API the JNI
// bridge (jni/llama_jni.cpp) calls. Built + run on an emulator/device by
// android/verify-llama-link.sh.
//
//   usage: llama-smoketest <model.gguf> [prompt] [maxTokens]
//
// CPU by default (Android GPU offload via Vulkan/OpenCL is a later tuning step).
#include "llama.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: llama-smoketest <model.gguf> [prompt] [maxTokens]\n"); return 2; }
    const char* modelPath = argv[1];
    std::string userText = argc >= 3 ? argv[2] : "Write three sentences about why the sky is blue.";
    int maxTokens = argc >= 4 ? atoi(argv[3]) : 96;
    std::string prompt = "<|im_start|>user\n" + userText + "<|im_end|>\n<|im_start|>assistant\n";

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;  // CPU
    llama_model* model = llama_model_load_from_file(modelPath, mp);
    if (!model) { printf("FAIL: model load\n"); return 1; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 2048;
    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) { printf("FAIL: context\n"); return 1; }
    const llama_vocab* vocab = llama_model_get_vocab(model);

    int nMax = (int)prompt.size() + 16;
    std::vector<llama_token> tokens(nMax);
    int n = llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(), tokens.data(), nMax, true, true);
    if (n <= 0) { printf("FAIL: tokenize (%d)\n", n); return 1; }
    tokens.resize(n);

    llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    auto piece = [&](llama_token tok) -> std::string {
        char buf[256];
        int c = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, true);
        return c > 0 ? std::string(buf, c) : std::string();
    };

    llama_batch batch = llama_batch_get_one(tokens.data(), (int)tokens.size());
    if (llama_decode(ctx, batch) != 0) { printf("FAIL: prompt decode\n"); return 1; }

    std::string out;
    int gen = 0;
    auto t1 = std::chrono::steady_clock::now();
    while (gen < maxTokens) {
        llama_token tok = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        out += piece(tok);
        gen++;
        batch = llama_batch_get_one(&tok, 1);
        if (llama_decode(ctx, batch) != 0) break;
    }
    double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();

    printf("ANSWER: %s\n", out.c_str());
    printf("REAL: decode %d tokens in %.2fs = %.1f tok/s [Android arm64, CPU]\n", gen, dt, gen / (dt > 0 ? dt : 1e-6));

    llama_sampler_free(smpl);
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
