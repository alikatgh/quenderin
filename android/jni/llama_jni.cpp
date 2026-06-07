// JNI bridge: the C++ side of ai.quenderin.core.LlamaEngine's `external fun`s.
// Compiled by the app module's externalNativeBuild (CMake) into libquenderin_llama.so
// for each ABI, linked against llama.cpp. llama.cpp stays C/C++ — this file is the only
// glue. See android/INTEGRATION.md for the build, and keep the llama.h calls in sync
// with the pinned llama.cpp commit (the API moves; this targets the post-2024
// vocab/sampler API). Twin of apple/.../LlamaEngine.swift.
//
// NOTE: not compiled in CI here (no NDK build in this environment) — build it in
// Android Studio. Treated as the on-device cliff, exactly like the iOS xcframework path.

#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include "llama.h"

#define LOG_TAG "QuenderinLlama"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// Everything one loaded model needs. The opaque jlong handle is a pointer to this.
struct LlamaHandle {
    llama_model*   model   = nullptr;
    llama_context* ctx     = nullptr;
    llama_sampler* sampler = nullptr;
};

bool g_backend_ready = false;

// Tokenize `text` with the model's vocab.
std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& text, bool add_bos) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, add_bos, true);
    std::vector<llama_token> tokens(n);
    llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, add_bos, true);
    return tokens;
}

std::string piece(const llama_vocab* vocab, llama_token tok) {
    char buf[256];
    int n = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, true);
    if (n < 0) return std::string();
    return std::string(buf, n);
}

// Run greedy generation. If `env`/`sink` are non-null, push each piece to sink.onToken().
std::string generate(LlamaHandle* h, const std::string& prompt, int max_tokens,
                     JNIEnv* env, jobject sink) {
    const llama_vocab* vocab = llama_model_get_vocab(h->model);

    std::vector<llama_token> tokens = tokenize(vocab, prompt, true);
    llama_batch batch = llama_batch_get_one(tokens.data(), (int32_t) tokens.size());

    jmethodID on_token = nullptr;
    if (env && sink) {
        jclass cls = env->GetObjectClass(sink);
        on_token = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)V");
    }

    std::string out;
    for (int i = 0; i < max_tokens; ++i) {
        if (llama_decode(h->ctx, batch) != 0) {
            LOGE("llama_decode failed");
            break;
        }
        llama_token next = llama_sampler_sample(h->sampler, h->ctx, -1);
        if (llama_vocab_is_eog(vocab, next)) break;

        std::string p = piece(vocab, next);
        out += p;
        if (on_token) {
            jstring js = env->NewStringUTF(p.c_str());
            env->CallVoidMethod(sink, on_token, js);
            env->DeleteLocalRef(js);
        }
        batch = llama_batch_get_one(&next, 1);
    }
    return out;
}

LlamaHandle* as_handle(jlong h) { return reinterpret_cast<LlamaHandle*>(h); }

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeLoad(JNIEnv* env, jobject /*thiz*/,
                                              jstring model_path, jint context_tokens, jint threads) {
    if (!g_backend_ready) { llama_backend_init(); g_backend_ready = true; }

    const char* path = env->GetStringUTFChars(model_path, nullptr);

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0; // CPU on mobile by default; Vulkan/GPU offload is a later tuning step
    llama_model* model = llama_model_load_from_file(path, mp);
    env->ReleaseStringUTFChars(model_path, path);
    if (!model) { LOGE("model load failed"); return 0; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx     = context_tokens > 0 ? (uint32_t) context_tokens : 4096;
    cp.n_threads = threads > 0 ? threads : 0; // 0 → llama.cpp picks
    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) { LOGE("context init failed"); llama_model_free(model); return 0; }

    llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    auto* h = new LlamaHandle{model, ctx, sampler};
    return reinterpret_cast<jlong>(h);
}

JNIEXPORT jstring JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeComplete(JNIEnv* env, jobject /*thiz*/,
                                                  jlong handle, jstring prompt, jint max_tokens) {
    LlamaHandle* h = as_handle(handle);
    const char* p = env->GetStringUTFChars(prompt, nullptr);
    std::string out = generate(h, std::string(p), max_tokens, nullptr, nullptr);
    env->ReleaseStringUTFChars(prompt, p);
    return env->NewStringUTF(out.c_str());
}

JNIEXPORT jstring JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeCompleteStreaming(JNIEnv* env, jobject /*thiz*/,
                                                           jlong handle, jstring prompt, jint max_tokens,
                                                           jobject sink) {
    LlamaHandle* h = as_handle(handle);
    const char* p = env->GetStringUTFChars(prompt, nullptr);
    std::string out = generate(h, std::string(p), max_tokens, env, sink);
    env->ReleaseStringUTFChars(prompt, p);
    return env->NewStringUTF(out.c_str());
}

JNIEXPORT void JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeFree(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    LlamaHandle* h = as_handle(handle);
    if (!h) return;
    if (h->sampler) llama_sampler_free(h->sampler);
    if (h->ctx)     llama_free(h->ctx);
    if (h->model)   llama_model_free(h->model);
    delete h;
}

} // extern "C"
