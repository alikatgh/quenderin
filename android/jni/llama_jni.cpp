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
#include <mutex>
#include "llama.h"
#include "llama_generate.h"   // the shared KV-reuse loop (also run on-device by the smoke test)

#define LOG_TAG "QuenderinLlama"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

// Route llama.cpp/ggml's own logs (model metadata, tensor loading, decode diagnostics) into Android
// logcat under LOG_TAG — otherwise they go to stderr and are INVISIBLE on-device, which is exactly
// what made an on-device "chat won't answer" impossible to diagnose. Registered once at backend init.
void android_llama_log(ggml_log_level level, const char* text, void* /*user*/) {
    if (!text) return;
    int prio = level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR
             : level == GGML_LOG_LEVEL_WARN  ? ANDROID_LOG_WARN
                                             : ANDROID_LOG_INFO;
    __android_log_print(prio, LOG_TAG, "%s", text);
}

// Everything one loaded model needs. The opaque jlong handle is a pointer to this.
struct LlamaHandle {
    llama_model*   model   = nullptr;
    llama_context* ctx     = nullptr;
    llama_sampler* sampler = nullptr;
    // The exact tokens resident in the KV cache (prior prompt + reply) — lets the next chat turn
    // decode only the new suffix instead of re-prefilling the whole history (mirrors KVCacheReuse).
    // Empty on a fresh handle (each load); reset implicitly because nativeFree deletes the handle.
    std::vector<llama_token> cached;
};

std::once_flag g_backend_once;  // llama_backend_init exactly once per process, race-free (H6)

// Tokenize `text` with the model's vocab.
std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& text, bool add_bos) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, add_bos, true);
    std::vector<llama_token> tokens(n);
    llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, add_bos, true);
    return tokens;
}

// Build a jstring from raw UTF-8 bytes via the byte[] + Charset constructor, NOT NewStringUTF.
// NewStringUTF expects JNI's "modified UTF-8" (rejects embedded NUL, encodes chars > U+FFFF as a
// 6-byte surrogate pair form) — llama_token_to_piece emits STANDARD UTF-8, so any piece containing
// a 4-byte sequence (emoji, several CJK extension blocks) is not valid modified UTF-8 and NewStringUTF
// can mangle or reject it (audit M2). "UTF-8" the charset-name literal is pure ASCII, so NewStringUTF
// is safe for THAT one string. Returns nullptr on OOM (caller checks, matching throw_oom's contract).
jstring make_jstring(JNIEnv* env, const std::string& s) {
    jbyteArray bytes = env->NewByteArray((jsize) s.size());
    if (!bytes) return nullptr;
    env->SetByteArrayRegion(bytes, 0, (jsize) s.size(), reinterpret_cast<const jbyte*>(s.data()));
    jclass stringCls = env->FindClass("java/lang/String");
    jmethodID ctor = env->GetMethodID(stringCls, "<init>", "([BLjava/lang/String;)V");
    jstring charset = env->NewStringUTF("UTF-8");
    jstring result = (jstring) env->NewObject(stringCls, ctor, bytes, charset);
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(stringCls);
    env->DeleteLocalRef(charset);
    return result;   // null here means NewObject threw (e.g. OOM) — a pending exception propagates
}

// Run generation with the handle's sampler (top-p + temperature, built in nativeLoad). If
// `env`/`sink` are non-null, push each piece to sink.onToken(). `failed` is set true only on a
// genuine, unrecoverable decode failure (never on a graceful context-limit stop) — see
// generateWithKVReuse's contract in llama_generate.h.
// `thiz` is the LlamaEngine instance; its boolean `cancelRequested` field is polled each token so
// a model switch can interrupt a running generation (audit M3).
//
// The decode loop itself (KV-reuse + strict mirror lockstep) lives in the shared `generateWithKVReuse`
// (llama_generate.h) so the on-device smoke test runs the EXACT same code. This function is the thin
// JNI adapter: tokenize, resolve the Java callbacks, and supply emit/cancel lambdas.
std::string generate(LlamaHandle* h, const std::string& prompt, int max_tokens,
                     JNIEnv* env, jobject sink, jobject thiz, bool& failed) {
    const llama_vocab* vocab = llama_model_get_vocab(h->model);

    std::vector<llama_token> newTokens = tokenize(vocab, prompt, true);
    LOGI("generate: prompt_bytes=%zu tokens=%zu max_tokens=%d cached=%zu", prompt.size(), newTokens.size(), max_tokens, h->cached.size());
    if (newTokens.empty()) return std::string();

    jmethodID on_token = nullptr;
    if (env && sink) {
        jclass cls = env->GetObjectClass(sink);
        on_token = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)V");
        env->DeleteLocalRef(cls);   // L3: don't pin the class local-ref for the whole stream
    }

    // Resolve the cancellation field once; polled lock-free each token (M3).
    jfieldID cancel_fid = nullptr;
    // Resolve LlamaEngine.recommendedThreads() once; called every ~32 tokens by generateWithKVReuse's
    // thermalPoll so a long generation sheds threads as the SoC heats (mirrors iOS's in-flight
    // ThermalGovernor — was previously applied only once, at nativeLoad time).
    jmethodID recommended_threads_mid = nullptr;
    if (env && thiz) {
        jclass tcls = env->GetObjectClass(thiz);
        cancel_fid = env->GetFieldID(tcls, "cancelRequested", "Z");
        recommended_threads_mid = env->GetMethodID(tcls, "recommendedThreads", "()I");
        env->DeleteLocalRef(tcls);
    }

    auto emit = [&](const std::string& p) -> bool {
        if (!on_token) return true;                     // non-streaming (nativeComplete): accumulate only
        jstring js = make_jstring(env, p);              // null on OOM (H5) — skip, keep going
        if (js) {
            env->CallVoidMethod(sink, on_token, js);
            env->DeleteLocalRef(js);
        }
        // If onToken threw, a JNI exception is now pending; the next JNI call would be UB and ART aborts
        // the whole process. Stop so it propagates cleanly (C3).
        return !env->ExceptionCheck();
    };
    auto cancelled = [&]() -> bool {
        return cancel_fid && env->GetBooleanField(thiz, cancel_fid);   // interrupted by a switch/cancel (M3)
    };

    // Only call llama_set_n_threads when the recommendation actually CHANGES (like iOS's governor,
    // which returns nil unless the level differs) — avoids a redundant native call every 32 tokens.
    int last_threads = 0;
    auto thermalPoll = [&]() -> int {
        if (!recommended_threads_mid) return 0;
        int n = env->CallIntMethod(thiz, recommended_threads_mid);
        if (n <= 0 || n == last_threads) return 0;
        last_threads = n;
        return n;
    };

    std::string result = quenderin::generateWithKVReuse(h->ctx, vocab, h->sampler, newTokens, max_tokens,
                                                         h->cached, emit, cancelled, &failed, thermalPoll);
    LOGI("generate: done failed=%d out_bytes=%zu", (int) failed, result.size());
    return result;
}

LlamaHandle* as_handle(jlong h) { return reinterpret_cast<LlamaHandle*>(h); }

// Throw a Java OutOfMemoryError (returns nullptr) so a marshaling failure surfaces as an error
// the UI can show, instead of a silent empty reply (audit L3).
jstring throw_oom(JNIEnv* env, const char* msg) {
    jclass cls = env->FindClass("java/lang/OutOfMemoryError");
    if (cls) env->ThrowNew(cls, msg);
    return nullptr;
}

// Throw when generateWithKVReuse reports a genuine, unrecoverable decode failure — so the Kotlin
// side (and the UI above it) sees a real error instead of an empty string indistinguishable from a
// legitimate empty reply (audit H2).
jstring throw_generation_failed(JNIEnv* env, const char* msg) {
    jclass cls = env->FindClass("java/lang/IllegalStateException");
    if (cls) env->ThrowNew(cls, msg);
    return nullptr;
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeLoad(JNIEnv* env, jobject /*thiz*/,
                                              jstring model_path, jint context_tokens, jint threads,
                                              jint kv_cache_quant, jfloat temperature, jfloat top_p,
                                              jint gpu_layers) {
    std::call_once(g_backend_once, [] {
        llama_log_set(android_llama_log, nullptr);   // llama.cpp logs → logcat, before anything loads
        llama_backend_init();
    });

    const char* path = env->GetStringUTFChars(model_path, nullptr);
    if (!path) return 0;   // OOM (H4)
    LOGI("nativeLoad: path=%s n_ctx=%d threads=%d gpu_layers=%d kv_quant=%d", path, context_tokens, threads, gpu_layers, kv_cache_quant);

    llama_model_params mp = llama_model_default_params();
    // GPU layers come from the Kotlin GpuOffloadPlanner (Adreno → all layers, else 0/CPU). A CPU-only
    // build (no Vulkan backend) clamps to 0 via the planner; even if it didn't, llama.cpp treats a
    // positive n_gpu_layers with no GPU backend as a no-op, so this can't fail a CPU build.
    mp.n_gpu_layers = gpu_layers; // mobile uses unified memory → all-or-nothing, no VRAM fit problem
    // Jetsam/LMK guard (this project's target class — memory-tight phones under background pressure):
    // mmap keeps weights pageable (fast cold start, OS-reclaimable); mlock is explicitly OFF so we
    // never wire multi-GB resident, which is exactly what triggers a low-memory kill on app switch.
    mp.use_mmap = true;
    mp.use_mlock = false;
    llama_model* model = llama_model_load_from_file(path, mp);
    env->ReleaseStringUTFChars(model_path, path);
    if (!model) { LOGE("model load failed"); return 0; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx     = context_tokens > 0 ? (uint32_t) context_tokens : 4096;
    cp.n_threads = threads > 0 ? threads : 0; // 0 → llama.cpp picks
    cp.n_threads_batch = cp.n_threads;         // prefill (prompt processing) used the default otherwise —
                                                // iOS sets both; leaving this unset made prefill slower
    // Quantize the KV cache on memory-tight devices (KVCacheType.nativeId: 0 f16, 1 q8_0). q8_0 is
    // safe for both K and V on the standard (non-flash-attention) path; the Kotlin side already sized
    // n_ctx for this dtype, so the smaller per-token cost buys back context instead of memory.
    if (kv_cache_quant == 1) {
        cp.type_k = GGML_TYPE_Q8_0;
        cp.type_v = GGML_TYPE_Q8_0;
    }
    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) { LOGE("context init failed"); llama_model_free(model); return 0; }

    // Sampler chain matching iOS (top-p → temperature → dist) so output isn't the repetitive,
    // loop-prone text greedy decoding produces. temperature <= 0 → deterministic greedy (honored).
    llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (temperature > 0.0f) {
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(top_p, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    }

    auto* h = new LlamaHandle{model, ctx, sampler};
    LOGI("nativeLoad: OK, handle=%p n_ctx=%u", (void*) h, cp.n_ctx);
    return reinterpret_cast<jlong>(h);
}

JNIEXPORT jstring JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeComplete(JNIEnv* env, jobject thiz,
                                                  jlong handle, jstring prompt, jint max_tokens) {
    LlamaHandle* h = as_handle(handle);
    if (!h) { LOGE("nativeComplete: null handle (no model loaded)"); return make_jstring(env, ""); }
    const char* p = env->GetStringUTFChars(prompt, nullptr);
    if (!p) return throw_oom(env, "GetStringUTFChars failed (out of memory)");   // OOM (H4/L3)
    bool failed = false;
    std::string out = generate(h, std::string(p), max_tokens, env, nullptr, thiz, failed);
    env->ReleaseStringUTFChars(prompt, p);
    // A genuine decode failure (audit H1/H2) — throw instead of returning an empty string that's
    // indistinguishable from a legitimate empty reply.
    if (failed) return throw_generation_failed(env, "llama_decode failed (context/model error)");
    return make_jstring(env, out);   // audit M2: real UTF-8, not modified-UTF-8
}

JNIEXPORT jstring JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeCompleteStreaming(JNIEnv* env, jobject thiz,
                                                           jlong handle, jstring prompt, jint max_tokens,
                                                           jobject sink) {
    LlamaHandle* h = as_handle(handle);
    if (!h) return make_jstring(env, "");
    const char* p = env->GetStringUTFChars(prompt, nullptr);
    if (!p) return throw_oom(env, "GetStringUTFChars failed (out of memory)");   // OOM (H4/L3)
    bool failed = false;
    std::string out = generate(h, std::string(p), max_tokens, env, sink, thiz, failed);
    env->ReleaseStringUTFChars(prompt, p);
    if (failed) return throw_generation_failed(env, "llama_decode failed (context/model error)");
    return make_jstring(env, out);
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
