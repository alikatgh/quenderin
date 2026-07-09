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
#include <algorithm>
#include "llama.h"
#include "ggml-backend.h"     // ggml_backend_load_all_from_path — runtime CPU-variant pick (DOTPROD/I8MM)
#include "ggml.h"             // ggml_threadpool_params (cpumask + strict_cpu)
#include "ggml-cpu.h"         // ggml_threadpool_new / free
#include "llama_generate.h"   // the shared KV-reuse loop (also run on-device by the smoke test)
#include <cstdio>
#include <cstring>

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
    // Pinned ggml threadpool (big-core affinity). Freed in nativeFree; null when affinity setup
    // was skipped (sysfs missing, threadpool API failed, or n_threads <= 0).
    ggml_threadpool_t threadpool = nullptr;
    // The exact tokens resident in the KV cache (prior prompt + reply) — lets the next chat turn
    // decode only the new suffix instead of re-prefilling the whole history (mirrors KVCacheReuse).
    // Empty on a fresh handle (each load); reset implicitly because nativeFree deletes the handle.
    std::vector<llama_token> cached;
    // Set true by the last generate() when it stopped at maxTokens (not EOG/cancel). Chat "Continue".
    bool hitTokenCap = false;
};

// Pin decode workers to the N fastest cores (by cpuinfo_max_freq) so the scheduler can't park a
// matmul thread on a LITTLE core mid-generation — the #4 lever from the PocketPal/llama.rn OSS
// audit. Builds a ggml_threadpool with strict_cpu + a filled cpumask and attaches it to the
// context. Returns the pool (caller owns + frees) or null on any soft failure (affinity is an
// optimization — never block model load over it). Twin of Kotlin ThreadPlanner.bestCoreIndices.
ggml_threadpool_t pin_threads(llama_context* ctx, int n_threads) {
    if (!ctx || n_threads <= 0) return nullptr;

    struct Core { int id; long freq; };
    std::vector<Core> cores;
    cores.reserve(16);
    for (int i = 0; i < GGML_MAX_N_THREADS; ++i) {
        char path[96];
        std::snprintf(path, sizeof(path),
                      "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        FILE* f = std::fopen(path, "r");
        if (!f) continue;
        long freq = 0;
        if (std::fscanf(f, "%ld", &freq) == 1 && freq > 0) cores.push_back({i, freq});
        std::fclose(f);
    }

    ggml_threadpool_params tpp = ggml_threadpool_params_default(n_threads);
    if (!cores.empty()) {
        std::sort(cores.begin(), cores.end(),
                  [](const Core& a, const Core& b) {
                      return a.freq != b.freq ? a.freq > b.freq : a.id < b.id;
                  });
        std::memset(tpp.cpumask, 0, sizeof(tpp.cpumask));
        const int n = std::min(n_threads, (int) cores.size());
        for (int i = 0; i < n; ++i) {
            if (cores[i].id >= 0 && cores[i].id < GGML_MAX_N_THREADS) {
                tpp.cpumask[cores[i].id] = true;
            }
        }
        tpp.strict_cpu = true;
        tpp.n_threads  = n_threads;
        LOGI("affinity: pinned %d threads to top-%d cores (fastest first)", n_threads, n);
    } else {
        LOGI("affinity: no cpufreq sysfs — using default (unpinned) threadpool of %d", n_threads);
    }

    ggml_threadpool_t tp = ggml_threadpool_new(&tpp);
    if (!tp) {
        LOGE("affinity: ggml_threadpool_new failed — decode will use the auto pool");
        return nullptr;
    }
    // Same pool for generate + batch (prefill); a second pool would double residency for little gain.
    llama_attach_threadpool(ctx, tp, tp);
    return tp;
}

std::once_flag g_backend_once;  // llama_backend_init exactly once per process, race-free (H6)

// Tokenize `text` with the model's vocab.
std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& text, bool add_bos) {
    const int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, add_bos, true);
    // The zero-capacity probe returns -(needed); n is the token count. Guard n <= 0: empty text yields 0
    // (→ empty result), and a future llama.cpp whose probe returns a POSITIVE value would make n negative —
    // passed to vector(n) as size_t it requests ~SIZE_MAX elements and crashes the process. Fail to an
    // empty tokenization instead of a bad_alloc. (adversarial-verify P3.)
    if (n <= 0) return {};
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
// `override_sampler` (default null) lets a single call decode with a PER-CALL sampler instead of the
// load-time `h->sampler` — used by nativeCompleteWithGrammar so a grammar-constrained agent decode can
// mask illegal tokens. The caller owns the override sampler's lifetime (builds + frees it).
// Per-generation "did we hit max_tokens?" flag read by Kotlin after completeChat (Continue UI).
// Stored on the handle so we don't need a new JNI out-param on every native method.
// Reset at the start of each generate(); observed after it returns.
std::string generate(LlamaHandle* h, const std::string& prompt, int max_tokens,
                     JNIEnv* env, jobject sink, jobject thiz, bool& failed,
                     llama_sampler* override_sampler = nullptr) {
    const llama_vocab* vocab = llama_model_get_vocab(h->model);
    h->hitTokenCap = false;

    std::vector<llama_token> newTokens = tokenize(vocab, prompt, true);
    LOGI("generate: prompt_bytes=%zu tokens=%zu max_tokens=%d cached=%zu", prompt.size(), newTokens.size(), max_tokens, h->cached.size());
    if (newTokens.empty()) return std::string();

    jmethodID on_token = nullptr;
    if (env && sink) {
        jclass cls = env->GetObjectClass(sink);
        on_token = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)V");
        env->DeleteLocalRef(cls);   // L3: don't pin the class local-ref for the whole stream
        // A failed lookup (R8/ProGuard rename or signature drift) leaves a pending NoSuchMethodError.
        // on_token==null is HANDLED (emit() falls back to accumulate), but the pending exception must be
        // cleared or the NEXT JNI call in the token loop is UB → ART aborts the whole process.
        if (!on_token && env->ExceptionCheck()) env->ExceptionClear();
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
        // Both are OPTIONAL (null-checked at their use sites: cancelled()/thermalPoll). A failed lookup
        // (renamed/removed member) leaves a pending NoSuchField/MethodError; clear it here or the decode
        // loop's next JNI call is UB → ART aborts the process. Same rule as thermalPoll's Q-338 guard.
        if (env->ExceptionCheck()) env->ExceptionClear();
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
        // Q-338: recommendedThreads() is a Java upcall — if it threw, a JNI exception is now pending and
        // the NEXT JNI call (cancelled()/emit(), same token loop) would be UB → ART aborts the whole
        // process. Unlike emit's C3 path (a CRITICAL callback, which propagates by stopping), thermalPoll
        // is a non-critical optimization: clear the exception and skip this adjustment so generation
        // continues rather than crashing over a thread-count hint.
        if (env->ExceptionCheck()) { env->ExceptionClear(); return 0; }
        if (n <= 0 || n == last_threads) return 0;
        last_threads = n;
        return n;
    };

    llama_sampler* active_sampler = override_sampler ? override_sampler : h->sampler;
    bool hitCap = false;
    std::string result = quenderin::generateWithKVReuse(h->ctx, vocab, active_sampler, newTokens, max_tokens,
                                                         h->cached, emit, cancelled, &failed, thermalPoll, &hitCap);
    h->hitTokenCap = hitCap;
    LOGI("generate: done failed=%d hitCap=%d out_bytes=%zu", (int) failed, (int) hitCap, result.size());
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

// Split `s` on the single-char delimiter `sep`.
std::vector<std::string> splitOn(const std::string& s, char sep) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
        size_t pos = s.find(sep, start);
        if (pos == std::string::npos) { out.push_back(s.substr(start)); break; }
        out.push_back(s.substr(start, pos - start));
        start = pos + 1;
    }
    return out;
}

// Turn the structured conversation into the prompt string the model was actually TRAINED on, using its
// OWN chat template embedded in the GGUF (llama_model_chat_template) via llama_chat_apply_template — e.g.
// Qwen's `<|im_start|>…<|im_end|>`, Llama-3's `<|start_header_id|>…<|eot_id|>`. This is what makes the model
// answer as an assistant AND emit its end-of-turn token, so generation STOPS after a short reply instead
// of running to max_tokens (the multi-second-per-reply slowness). `payload` is role\x1Ftext records joined
// by \x1E (system first). Falls back to a plain "User:/Assistant:" prompt if the model has no template.
std::string buildChatPrompt(llama_model* model, const std::string& payload, bool& templated, bool disableThinking) {
    templated = false;
    std::vector<std::pair<std::string, std::string>> msgs;
    for (const auto& rec : splitOn(payload, '\x1E')) {
        if (rec.empty()) continue;
        auto rt = splitOn(rec, '\x1F');
        if (rt.size() == 2) msgs.emplace_back(rt[0], rt[1]);
    }
    if (msgs.empty()) return std::string();

    const char* tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl) {
        std::vector<llama_chat_message> cm;
        cm.reserve(msgs.size());
        for (const auto& m : msgs) cm.push_back({m.first.c_str(), m.second.c_str()});
        size_t est = 512;
        for (const auto& m : msgs) est += m.first.size() + m.second.size();
        std::vector<char> buf(est * 2);
        int32_t n = llama_chat_apply_template(tmpl, cm.data(), cm.size(), true, buf.data(), (int32_t) buf.size());
        if (n > (int32_t) buf.size()) {              // buffer too small — grow once and retry
            buf.resize(n);
            n = llama_chat_apply_template(tmpl, cm.data(), cm.size(), true, buf.data(), n);
        }
        if (n > 0) {
            std::string result(buf.data(), (size_t) n);
            // Turn OFF extended reasoning for "thinking" models (Qwen3, DeepSeek-R1). By default they emit
            // a long <think>…</think> chain BEFORE the answer — on a phone that's tens of seconds per reply
            // AND the user reads raw reasoning instead of the response. Closing an EMPTY think block right
            // after the assistant turn makes the model answer directly (Qwen3's `enable_thinking=false`
            // behaviour). Detected by the model's template gating <think>/enable_thinking; other models are
            // untouched. Normalize whether or not the applied template already opened a <think>.
            std::string t(tmpl);
            if (disableThinking &&
                (t.find("enable_thinking") != std::string::npos || t.find("<think>") != std::string::npos)) {
                size_t lastOpen = result.rfind("<think>");
                size_t lastClose = result.rfind("</think>");
                bool openUnclosed = lastOpen != std::string::npos &&
                                    (lastClose == std::string::npos || lastClose < lastOpen);
                result += openUnclosed ? "\n</think>\n\n" : "<think>\n\n</think>\n\n";
            }
            templated = true;
            return result;
        }
    }

    // Fallback: the old flat prompt (still works, just no early-stop benefit).
    std::string flat;
    for (const auto& m : msgs) {
        if (m.first == "system") { flat += m.second; flat += "\n\n"; }
        else { flat += (m.first == "user" ? "User: " : "Assistant: "); flat += m.second; flat += "\n"; }
    }
    flat += "Assistant:";
    return flat;
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeLoad(JNIEnv* env, jobject /*thiz*/,
                                              jstring model_path, jint context_tokens, jint threads,
                                              jint kv_cache_quant, jfloat temperature, jfloat top_p,
                                              jint gpu_layers, jstring native_lib_dir) {
    // The app's nativeLibraryDir, where Gradle unpacked the ggml CPU-variant backends
    // (libggml-cpu-android_armv*.so). Loaded once; ggml scores them against the live CPU and
    // registers the best (e.g. armv8.6 DOTPROD+I8MM on an S23) — the fast matmul kernels a single
    // generic arm64 build never used. Empty string → statically-linked default (old builds, tests).
    std::string libDir;
    if (native_lib_dir) {
        if (const char* d = env->GetStringUTFChars(native_lib_dir, nullptr)) {
            libDir = d;
            env->ReleaseStringUTFChars(native_lib_dir, d);
        }
    }
    std::call_once(g_backend_once, [&libDir] {
        llama_log_set(android_llama_log, nullptr);   // llama.cpp logs → logcat, before anything loads
        if (!libDir.empty()) {
            ggml_backend_load_all_from_path(libDir.c_str());
        }
        LOGI("backends: %zu device(s) after variant scan of '%s'", ggml_backend_dev_count(), libDir.c_str());
        if (ggml_backend_dev_count() == 0) {
            // Variant scan found nothing usable (unexpected) — fall back to the default search
            // (executable dir / GGML_BACKEND_DIR) rather than failing every model load.
            ggml_backend_load_all();
            LOGI("backends: %zu device(s) after fallback load_all", ggml_backend_dev_count());
        }
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
    // Explicit prefill batch sizes (OSS audit: every surveyed llama.cpp mobile app sets 512/512).
    // Never exceed n_ctx on tight devices where the budgeter picked a small window.
    cp.n_batch  = std::min<uint32_t>(512, cp.n_ctx);
    cp.n_ubatch = cp.n_batch;
    // Flash Attention EXPLICITLY on AUTO (twin of iOS LlamaEngine.loadLocked): llama.cpp enables
    // it whenever the model supports it, and resolves to disabled — not a hard failure — when it
    // can't. The pinned llama.cpp's default already IS auto, but that default was `false` in older
    // versions; pin the behavior instead of trusting a default that has changed before.
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    // Quantize the KV cache on memory-tight devices (KVCacheType.nativeId: 0 f16, 1 q8_0). NB: in
    // modern llama.cpp a QUANTIZED V-cache requires Flash Attention — fine wherever FA auto-enables;
    // the retry below covers models where AUTO resolves to disabled. The Kotlin side already sized
    // n_ctx for this dtype, so the smaller per-token cost buys back context instead of memory.
    if (kv_cache_quant == 1) {
        cp.type_k = GGML_TYPE_Q8_0;
        cp.type_v = GGML_TYPE_Q8_0;
    }
    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx && kv_cache_quant == 1) {
        // Quantized V-cache without Flash Attention support → init fails. Retry with f16 KV (more
        // memory, always valid) rather than failing the load on exactly the memory-tight devices
        // that picked q8_0. Twin of iOS LlamaEngine.loadLocked's fallback.
        LOGE("context init failed with q8_0 KV cache — retrying with f16 (model likely lacks flash-attention support)");
        cp.type_k = GGML_TYPE_F16;
        cp.type_v = GGML_TYPE_F16;
        ctx = llama_init_from_model(model, cp);
    }
    if (!ctx) { LOGE("context init failed"); llama_model_free(model); return 0; }

    // Sampler chain matching shared/sampling-profiles.json → chat + iOS GenerationOptions:
    //   penalties (rep 1.1 / last-n 256) → top_k 40 → top-p → temperature → dist
    // The repetition penalty is what keeps Q2-class small models from looping the same paragraph.
    // temperature <= 0 → deterministic greedy (honored), still with the penalty stage first.
    llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    constexpr float kRepeatPenalty = 1.1f;
    constexpr int   kRepeatLastN   = 256;
    constexpr int   kChatTopK      = 40;   // sampling-profiles.json chat.top_k
    llama_sampler_chain_add(sampler, llama_sampler_init_penalties(kRepeatLastN, kRepeatPenalty, 0.0f, 0.0f));
    if (temperature > 0.0f) {
        if (kChatTopK > 0) llama_sampler_chain_add(sampler, llama_sampler_init_top_k(kChatTopK));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(top_p, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    }

    // Pin workers to big cores (strict_cpu + cpumask). Soft-fail: null pool is fine.
    const int pin_n = threads > 0 ? (int) threads : (int) cp.n_threads;
    ggml_threadpool_t tp = pin_threads(ctx, pin_n > 0 ? pin_n : 1);

    auto* h = new LlamaHandle{model, ctx, sampler, tp};
    LOGI("nativeLoad: OK, handle=%p n_ctx=%u affinity=%s", (void*) h, cp.n_ctx, tp ? "on" : "off");
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

// GRAMMAR-CONSTRAINED completion (the agent decision decode): build a PER-CALL sampler whose first
// stage is a GBNF grammar mask, so the decode CANNOT be prose — parity with the iOS LlamaEngine chain
// (grammar → penalties → top_k → top_p → temp → dist; top_k/top_p run AFTER the grammar so they only
// trim already-legal tokens). A grammar that fails to parse returns null → we skip it and decode with
// the remaining (unconstrained) chain, mirroring iOS's null-grammar fallback rather than crashing.
JNIEXPORT jstring JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeCompleteWithGrammar(JNIEnv* env, jobject thiz,
                                                             jlong handle, jstring prompt, jint max_tokens,
                                                             jstring grammar, jfloat top_p, jint top_k,
                                                             jfloat temperature, jfloat repeat_penalty,
                                                             jint repeat_last_n) {
    LlamaHandle* h = as_handle(handle);
    if (!h) { LOGE("nativeCompleteWithGrammar: null handle (no model loaded)"); return make_jstring(env, ""); }
    const char* p = env->GetStringUTFChars(prompt, nullptr);
    if (!p) return throw_oom(env, "GetStringUTFChars failed (out of memory)");   // OOM (H4/L3)
    const char* g = grammar ? env->GetStringUTFChars(grammar, nullptr) : nullptr;

    const llama_vocab* vocab = llama_model_get_vocab(h->model);
    llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (g && g[0] != '\0') {
        llama_sampler* gs = llama_sampler_init_grammar(vocab, g, "root");   // null if the GBNF won't parse
        if (gs) llama_sampler_chain_add(smpl, gs);
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(repeat_last_n, repeat_penalty, 0.0f, 0.0f));
    if (top_k > 0) llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    bool failed = false;
    std::string out = generate(h, std::string(p), max_tokens, env, nullptr, thiz, failed, smpl);
    llama_sampler_free(smpl);                          // per-call: freed here, never touches h->sampler
    env->ReleaseStringUTFChars(prompt, p);
    if (g) env->ReleaseStringUTFChars(grammar, g);
    if (failed) return throw_generation_failed(env, "llama_decode failed (context/model error)");
    return make_jstring(env, out);
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

// Chat-templated streaming completion: `payload` is the structured conversation (role\x1Ftext records
// joined by \x1E, system first). We apply the model's own chat template so it answers as an assistant and
// stops at its end-of-turn token — dramatically faster + higher quality than the raw "User:/Assistant:"
// prompt. Streams pieces to `sink`; returns the full text.
JNIEXPORT jstring JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeCompleteChatStreaming(JNIEnv* env, jobject thiz,
                                                               jlong handle, jstring payload,
                                                               jint max_tokens, jboolean disable_thinking,
                                                               jobject sink) {
    LlamaHandle* h = as_handle(handle);
    if (!h) { LOGE("nativeCompleteChat: null handle (no model loaded)"); return make_jstring(env, ""); }
    const char* p = env->GetStringUTFChars(payload, nullptr);
    if (!p) return throw_oom(env, "GetStringUTFChars failed (out of memory)");
    std::string payloadStr(p);
    env->ReleaseStringUTFChars(payload, p);

    bool templated = false;
    std::string prompt = buildChatPrompt(h->model, payloadStr, templated, disable_thinking == JNI_TRUE);
    LOGI("nativeCompleteChat: templated=%d no_think=%d prompt_bytes=%zu", (int) templated, (int) disable_thinking, prompt.size());
    if (prompt.empty()) return make_jstring(env, "");

    bool failed = false;
    std::string out = generate(h, prompt, max_tokens, env, sink, thiz, failed);
    if (failed) return throw_generation_failed(env, "llama_decode failed (context/model error)");
    return make_jstring(env, out);
}

JNIEXPORT void JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeFree(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    LlamaHandle* h = as_handle(handle);
    if (!h) return;
    if (h->sampler) llama_sampler_free(h->sampler);
    // Detach + free the pinned pool BEFORE freeing the context (pool must outlive attach use).
    if (h->ctx) {
        if (h->threadpool) llama_detach_threadpool(h->ctx);
        llama_free(h->ctx);
    }
    if (h->threadpool) ggml_threadpool_free(h->threadpool);
    if (h->model)   llama_model_free(h->model);
    delete h;
}

// Did the most recent generate() stop because it hit maxTokens? ChatModel reads this for "Continue".
JNIEXPORT jboolean JNICALL
Java_ai_quenderin_core_LlamaEngine_nativeLastHitTokenCap(JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    LlamaHandle* h = as_handle(handle);
    return (h && h->hitTokenCap) ? JNI_TRUE : JNI_FALSE;
}

} // extern "C"
