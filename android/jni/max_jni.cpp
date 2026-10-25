// JNI binding for the portable MAX model boundary.
//
// The canonical C implementation (native/max-runtime) is compiled once into
// this library. No vendor runner is linked in the app build: nativeOpen reports
// unavailable until a reviewed runner exists. Hosted JNI/JVM tests compile the
// same bridge with QUENDERIN_MAX_TEST_RUNNER and the synthetic runner fixture.
//
// Handles are registry IDs, never raw pointers. The registry keeps a shared_ptr
// alive for the duration of each call, so a concurrent close cannot free state
// under a caller. The Java-side lease (running) and the C-side lease are both
// required before a generation can touch the model.

#include <jni.h>
#include "jni_utf8.h"
#include "quenderin_max_model.h"

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>

#ifdef QUENDERIN_MAX_TEST_RUNNER
#include "fake_model_runner.h"
#endif

namespace {

constexpr jint kBridgeAbi = 1;

const QMaxModelRunner* compiled_runner() {
#ifdef QUENDERIN_MAX_TEST_RUNNER
    return fake_model_runner();
#else
    return nullptr;
#endif
}

struct MaxHandle {
    QMaxModel* model = nullptr;
    JavaVM* vm = nullptr;
    std::atomic<jlong> current_run{0};
    std::atomic<jlong> cancel_requested{0};
    std::atomic<bool> running{false};
    jlong pending_cancel = 0;
    std::mutex run_mutex;
    std::mutex model_mutex;
};

struct StopContext {
    MaxHandle* handle = nullptr;
    jlong run_id = 0;
};

int stop_requested(void* context) {
    auto* stop = static_cast<StopContext*>(context);
    return stop && stop->handle->cancel_requested.load() == stop->run_id ? 1 : 0;
}

std::mutex g_registry_mutex;
std::unordered_map<jlong, std::shared_ptr<MaxHandle>> g_handles;
std::atomic<jlong> g_next_id{1};

std::shared_ptr<MaxHandle> handle_for(jlong id) {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    const auto found = g_handles.find(id);
    return found == g_handles.end() ? nullptr : found->second;
}

struct ReceiptStorage {
    std::vector<std::string> paths;
    std::vector<std::string> hashes;
    std::string runner;
    std::string backend;
    std::vector<QMaxModelFile> files;
    QMaxModelReceipt receipt{};
};

bool valid_sha256(const std::string& value) {
    if (value.size() != 64) return false;
    for (char c : value) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

bool build_receipt_impl(JNIEnv* env, jobjectArray path_array, jlongArray size_array,
                        jobjectArray hash_array, jstring runner_name, jstring backend_name,
                        jint context_tokens, jint max_output_tokens, ReceiptStorage* out) {
    if (!out || !path_array || !size_array || !hash_array || !runner_name || !backend_name) return false;
    const jsize count = env->GetArrayLength(path_array);
    if (count < 1 || count > QMAX_MODEL_MAX_FILES) return false;
    if (env->GetArrayLength(size_array) != count || env->GetArrayLength(hash_array) != count) return false;
    std::vector<jlong> sizes(static_cast<size_t>(count));
    env->GetLongArrayRegion(size_array, 0, count, sizes.data());
    if (env->ExceptionCheck()) return false;
    out->paths.reserve(static_cast<size_t>(count));
    out->hashes.reserve(static_cast<size_t>(count));
    bool ok = true;
    for (jsize i = 0; i < count && ok; ++i) {
        auto* path = static_cast<jstring>(env->GetObjectArrayElement(path_array, i));
        auto* hash = static_cast<jstring>(env->GetObjectArrayElement(hash_array, i));
        if (!path || !hash) {
            ok = false;
        } else {
            try {
                out->paths.push_back(quenderin::jni::utf8(env, path, QMAX_MODEL_MAX_PATH_BYTES));
                const auto hash_value = quenderin::jni::utf8(env, hash, 64);
                if (!valid_sha256(hash_value)) {
                    ok = false;
                } else {
                    out->hashes.push_back(hash_value);
                }
            } catch (...) {
                ok = false;
            }
        }
        if (path) env->DeleteLocalRef(path);
        if (hash) env->DeleteLocalRef(hash);
        if (sizes[i] < 1) ok = false;
    }
    if (!ok || env->ExceptionCheck()) return false;
    try {
        out->runner = quenderin::jni::utf8(env, runner_name, 63);
        out->backend = quenderin::jni::utf8(env, backend_name, 15);
    } catch (...) {
        return false;
    }
    out->files.reserve(static_cast<size_t>(count));
    for (jsize i = 0; i < count; ++i) {
        QMaxModelFile file{};
        file.path = out->paths[static_cast<size_t>(i)].c_str();
        file.bytes = static_cast<uint64_t>(sizes[static_cast<size_t>(i)]);
        std::memcpy(file.sha256, out->hashes[static_cast<size_t>(i)].c_str(), 64);
        file.sha256[64] = '\0';
        out->files.push_back(file);
    }
    out->receipt.runner_name = out->runner.c_str();
    out->receipt.runner_abi = QMAX_MODEL_RUNNER_ABI;
    out->receipt.backend = out->backend.c_str();
    out->receipt.context_tokens = static_cast<uint32_t>(context_tokens);
    out->receipt.max_output_tokens = static_cast<uint32_t>(max_output_tokens);
    out->receipt.files = out->files.data();
    out->receipt.file_count = out->files.size();
    return true;
}

bool build_receipt(JNIEnv* env, jobjectArray path_array, jlongArray size_array,
                   jobjectArray hash_array, jstring runner_name, jstring backend_name,
                   jint context_tokens, jint max_output_tokens, ReceiptStorage* out) {
    try {
        return build_receipt_impl(env, path_array, size_array, hash_array, runner_name,
                                  backend_name, context_tokens, max_output_tokens, out);
    } catch (const std::bad_alloc&) {
        return false;
    } catch (...) {
        return false;
    }
}

std::string bounded_message(const QMaxError& error, const char* fallback) {
    if (!error.message[0]) return fallback;
    size_t length = 0;
    while (length < sizeof(error.message) && error.message[length]) ++length;
    return std::string(error.message, length);
}

void set_text_at(JNIEnv* env, jobjectArray out, jsize index, const std::string& message) {
    if (!out || env->ExceptionCheck() || index < 0 || env->GetArrayLength(out) <= index) return;
    jstring value = quenderin::jni::java_string(env, message);
    if (!value) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return;
    }
    env->SetObjectArrayElement(out, index, value);
    env->DeleteLocalRef(value);
}

void set_error(JNIEnv* env, jobjectArray out, const std::string& message) {
    set_text_at(env, out, 0, message);
}

void set_performance(JNIEnv* env, jdoubleArray out, const QMaxModelPerformance& performance) {
    if (!out || env->ExceptionCheck() || env->GetArrayLength(out) < 8) return;
    const jdouble values[8] = {
        static_cast<jdouble>(performance.prompt_tokens),
        static_cast<jdouble>(performance.decoded_tokens),
        performance.prefill_ms,
        performance.decode_ms,
        performance.first_token_ms,
        performance.max_gap_ms,
        static_cast<jdouble>(performance.status),
        static_cast<jdouble>(performance.cache_mode),
    };
    env->SetDoubleArrayRegion(out, 0, 8, values);
}

void set_capability(JNIEnv* env, jintArray result, jobjectArray text,
                    const QMaxModelCapability& capability) {
    if (result && !env->ExceptionCheck() && env->GetArrayLength(result) >= 5) {
        const jint values[5] = {
            capability.contract_ok, capability.load_probe_passed, capability.available,
            static_cast<jint>(capability.context_tokens), static_cast<jint>(capability.max_output_tokens),
        };
        env->SetIntArrayRegion(result, 0, 5, values);
    }
    if (!text || env->ExceptionCheck() || env->GetArrayLength(text) < 3) return;
    const char* strings[3] = {capability.runner, capability.backend, capability.reason};
    for (jint i = 0; i < 3; ++i) {
        jstring value = quenderin::jni::java_string(env, strings[i]);
        if (!value) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            continue;
        }
        env->SetObjectArrayElement(text, i, value);
        env->DeleteLocalRef(value);
    }
}

class EnvScope {
public:
    explicit EnvScope(JavaVM* vm) : vm_(vm) {
        if (!vm_) return;
        const jint state = vm_->GetEnv(reinterpret_cast<void**>(&env_), JNI_VERSION_1_6);
        if (state == JNI_EDETACHED) {
#ifdef __ANDROID__
            if (vm_->AttachCurrentThread(&env_, nullptr) == JNI_OK) attached_ = true;
#else
            if (vm_->AttachCurrentThread(reinterpret_cast<void**>(&env_), nullptr) == JNI_OK) attached_ = true;
#endif
            else env_ = nullptr;
        } else if (state != JNI_OK) {
            env_ = nullptr;
        }
    }
    ~EnvScope() {
        if (attached_ && vm_) vm_->DetachCurrentThread();
    }
    EnvScope(const EnvScope&) = delete;
    EnvScope& operator=(const EnvScope&) = delete;
    JNIEnv* env() const { return env_; }

private:
    JavaVM* vm_;
    JNIEnv* env_ = nullptr;
    bool attached_ = false;
};

struct EmitContext {
    JavaVM* vm = nullptr;
    jobject sink = nullptr;
    jmethodID on_token = nullptr;
};

int emit_token(void* context, const char* utf8, size_t bytes) {
    auto* emit = static_cast<EmitContext*>(context);
    if (!emit || !emit->sink || !emit->on_token) return 0;
    EnvScope scope(emit->vm);
    if (!scope.env() || scope.env()->ExceptionCheck()) return 0;
    jstring value = nullptr;
    try {
        value = quenderin::jni::java_string(scope.env(), std::string(utf8, bytes));
    } catch (...) {
        return 0;
    }
    if (!value) return 0;
    const jboolean keep = scope.env()->CallBooleanMethod(emit->sink, emit->on_token, value);
    scope.env()->DeleteLocalRef(value);
    if (scope.env()->ExceptionCheck()) return 0;
    return keep == JNI_TRUE ? 1 : 0;
}

struct GlobalRef {
    JNIEnv* env = nullptr;
    jobject ref = nullptr;
    ~GlobalRef() {
        if (ref) env->DeleteGlobalRef(ref);
    }
    GlobalRef(const GlobalRef&) = delete;
    GlobalRef& operator=(const GlobalRef&) = delete;
};

jint throw_out_of_memory(JNIEnv* env, const char* message) {
    quenderin::jni::fail(env, "java/lang/OutOfMemoryError", message);
    return QMAX_UNAVAILABLE;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeBridgeAbi(JNIEnv*, jclass) {
    return kBridgeAbi;
}

JNIEXPORT jint JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeVerify(
        JNIEnv* env, jclass, jobjectArray paths, jlongArray sizes, jobjectArray hashes,
        jstring runner, jstring backend, jint context_tokens, jint max_output_tokens,
        jobjectArray error_out) {
    QMaxError error{};
    ReceiptStorage storage;
    if (!build_receipt(env, paths, sizes, hashes, runner, backend, context_tokens,
                       max_output_tokens, &storage)) {
        set_error(env, error_out, "Invalid MAX model receipt.");
        return QMAX_INVALID_ARGUMENT;
    }
    const QMaxCode code = qmax_model_verify(&storage.receipt, &error);
    set_error(env, error_out, bounded_message(error, "MAX artifact verification failed."));
    return code;
}

JNIEXPORT jint JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeCapability(
        JNIEnv* env, jclass, jobjectArray paths, jlongArray sizes, jobjectArray hashes,
        jstring runner, jstring backend, jint context_tokens, jint max_output_tokens,
        jboolean load_probe_passed, jintArray result, jobjectArray text) {
    ReceiptStorage storage;
    if (!build_receipt(env, paths, sizes, hashes, runner, backend, context_tokens,
                       max_output_tokens, &storage)) {
        set_text_at(env, text, 2, "Invalid MAX model receipt.");
        return QMAX_INVALID_ARGUMENT;
    }
    const QMaxModelRunner* compiled = compiled_runner();
    if (!compiled) {
        if (result && env->GetArrayLength(result) >= 5) {
            const jint values[5] = {0, load_probe_passed ? 1 : 0, 0, 0, 0};
            env->SetIntArrayRegion(result, 0, 5, values);
        }
        set_text_at(env, text, 2, "This build does not include a verified MAX runner.");
        return QMAX_UNAVAILABLE;
    }
    QMaxModelCapability capability{};
    const QMaxCode code = qmax_model_capability(compiled, &storage.receipt,
                                                load_probe_passed ? 1 : 0, &capability);
    set_capability(env, result, text, capability);
    return code;
}

JNIEXPORT jlong JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeOpen(
        JNIEnv* env, jclass, jobjectArray paths, jlongArray sizes, jobjectArray hashes,
        jstring runner, jstring backend, jint context_tokens, jint max_output_tokens,
        jintArray code_out, jobjectArray error_out) {
    QMaxError error{};
    ReceiptStorage storage;
    if (!build_receipt(env, paths, sizes, hashes, runner, backend, context_tokens,
                       max_output_tokens, &storage)) {
        if (code_out) {
            const jint code = QMAX_INVALID_ARGUMENT;
            env->SetIntArrayRegion(code_out, 0, 1, &code);
        }
        set_error(env, error_out, "Invalid MAX model receipt.");
        return 0;
    }
    const QMaxModelRunner* compiled = compiled_runner();
    if (!compiled) {
        if (code_out) {
            const jint code = QMAX_UNAVAILABLE;
            env->SetIntArrayRegion(code_out, 0, 1, &code);
        }
        set_error(env, error_out, "This build does not include a verified MAX runner.");
        return 0;
    }
    QMaxModel* model = nullptr;
    const QMaxCode opened = qmax_model_open(compiled, &storage.receipt, &model, &error);
    if (opened != QMAX_OK || !model) {
        if (code_out) {
            const jint code = opened == QMAX_OK ? QMAX_UNAVAILABLE : opened;
            env->SetIntArrayRegion(code_out, 0, 1, &code);
        }
        set_error(env, error_out, bounded_message(error, "The MAX model could not be opened."));
        return 0;
    }
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK || !vm) {
        qmax_model_close(model);
        if (code_out) {
            const jint code = QMAX_UNAVAILABLE;
            env->SetIntArrayRegion(code_out, 0, 1, &code);
        }
        set_error(env, error_out, "The JVM is unavailable for MAX callbacks.");
        return 0;
    }
    std::shared_ptr<MaxHandle> handle;
    try {
        handle = std::make_shared<MaxHandle>();
    } catch (const std::bad_alloc&) {
        qmax_model_close(model);
        if (code_out) {
            const jint code = QMAX_UNAVAILABLE;
            env->SetIntArrayRegion(code_out, 0, 1, &code);
        }
        return throw_out_of_memory(env, "Cannot allocate the MAX model handle.");
    }
    handle->model = model;
    handle->vm = vm;
    const jlong id = g_next_id.fetch_add(1);
    try {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        g_handles.emplace(id, handle);
    } catch (const std::bad_alloc&) {
        qmax_model_close(model);
        if (code_out) {
            const jint code = QMAX_UNAVAILABLE;
            env->SetIntArrayRegion(code_out, 0, 1, &code);
        }
        return throw_out_of_memory(env, "Cannot retain the MAX model handle.");
    }
    if (code_out) {
        const jint code = QMAX_OK;
        env->SetIntArrayRegion(code_out, 0, 1, &code);
    }
    set_error(env, error_out, "");
    return id;
}

JNIEXPORT jint JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeGenerate(
        JNIEnv* env, jclass, jlong id, jlong run_id, jstring prompt, jint max_tokens,
        jfloat temperature, jfloat top_p, jint seed, jobject sink,
        jdoubleArray performance_out, jobjectArray error_out) {
    QMaxError error{};
    QMaxModelPerformance performance{};
    performance.status = 6;
    auto handle = handle_for(id);
    QMaxModel* model = nullptr;
    if (handle) {
        std::lock_guard<std::mutex> lock(handle->model_mutex);
        model = handle->model;
    }
    if (!handle || !model) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "MAX model handle is closed or unknown.");
        return QMAX_INVALID_ARGUMENT;
    }
    bool expected = false;
    if (!handle->running.compare_exchange_strong(expected, true)) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "Generation is already in progress for this model.");
        return QMAX_BUSY;
    }
    struct RunningGuard {
        MaxHandle* handle;
        ~RunningGuard() { handle->running.store(false); }
    } running_guard{handle.get()};
    struct RunGuard {
        MaxHandle* handle;
        jlong run_id;
        ~RunGuard() {
            std::lock_guard<std::mutex> lock(handle->run_mutex);
            if (handle->current_run.load() == run_id) handle->current_run.store(0);
            if (handle->cancel_requested.load() == run_id) handle->cancel_requested.store(0);
        }
    } run_guard{handle.get(), run_id};
    bool pre_cancelled = false;
    {
        std::lock_guard<std::mutex> lock(handle->run_mutex);
        if (handle->pending_cancel == run_id) {
            handle->pending_cancel = 0;
            pre_cancelled = true;
        } else {
            handle->pending_cancel = 0;
            handle->current_run.store(run_id);
            handle->cancel_requested.store(0);
        }
    }
    if (pre_cancelled) {
        performance.status = 1;
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "Generation cancelled before native admission.");
        return QMAX_CANCELLED;
    }
    {
        std::lock_guard<std::mutex> lock(handle->model_mutex);
        model = handle->model;
    }
    if (!model) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "MAX model handle is closed or unknown.");
        return QMAX_INVALID_ARGUMENT;
    }

    std::string prompt_bytes;
    try {
        prompt_bytes = quenderin::jni::utf8(env, prompt, QMAX_MODEL_MAX_PROMPT_BYTES, true);
    } catch (...) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "Prompt is outside the bounded UTF-8 request size.");
        return QMAX_INVALID_ARGUMENT;
    }
    if (!sink) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "A token sink is required.");
        return QMAX_INVALID_ARGUMENT;
    }
    jmethodID on_token = nullptr;
    if (jclass sink_class = env->GetObjectClass(sink)) {
        on_token = env->GetMethodID(sink_class, "onToken", "(Ljava/lang/String;)Z");
        env->DeleteLocalRef(sink_class);
    }
    if (!on_token) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "The token sink does not implement onToken(String): Boolean.");
        return QMAX_INVALID_ARGUMENT;
    }
    jobject sink_ref = env->NewGlobalRef(sink);
    if (!sink_ref) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, "Cannot retain the token sink.");
        return QMAX_UNAVAILABLE;
    }
    GlobalRef retained{env, sink_ref};

    QMaxModelRequest request{};
    request.prompt = prompt_bytes.data();
    request.prompt_bytes = prompt_bytes.size();
    request.max_tokens = static_cast<uint32_t>(max_tokens);
    request.temperature = temperature;
    request.top_p = top_p;
    request.seed = static_cast<uint32_t>(seed);
    EmitContext emit{handle->vm, sink_ref, on_token};
    StopContext stop{handle.get(), run_id};
    const QMaxCode code = qmax_model_generate(model, &request, emit_token, &emit,
                                              stop_requested, &stop, &performance, &error);
    if (!env->ExceptionCheck()) {
        set_performance(env, performance_out, performance);
        set_error(env, error_out, bounded_message(error, "MAX generation failed."));
    }
    return code;
}

JNIEXPORT jboolean JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeCancel(JNIEnv*, jclass, jlong id, jlong run_id) {
    if (run_id <= 0) return JNI_FALSE;
    auto handle = handle_for(id);
    if (!handle) return JNI_FALSE;
    std::lock_guard<std::mutex> model_lock(handle->model_mutex);
    if (!handle->model) return JNI_FALSE;
    std::lock_guard<std::mutex> run_lock(handle->run_mutex);
    if (handle->current_run.load() == run_id) {
        handle->cancel_requested.store(run_id);
        qmax_model_cancel(handle->model);
        return JNI_TRUE;
    }
    if (handle->current_run.load() == 0) {
        // The wrapper published this run before JNI registered it. Hold the
        // request until nativeGenerate consumes it (or a different run starts).
        handle->pending_cancel = run_id;
        return JNI_TRUE;
    }
    return JNI_FALSE;  // a different run owns the lease; never cancel it
}

JNIEXPORT jint JNICALL
Java_ai_quenderin_core_MaxModelNative_nativeClose(JNIEnv*, jclass, jlong id) {
    auto handle = handle_for(id);
    if (!handle) return QMAX_INVALID_ARGUMENT;
    bool expected = false;
    if (!handle->running.compare_exchange_strong(expected, true)) return QMAX_BUSY;
    QMaxCode code = QMAX_RUNTIME_ERROR;
    {
        std::lock_guard<std::mutex> model_lock(handle->model_mutex);
        if (!handle->model) {
            handle->running.store(false);
            return QMAX_OK;
        }
        code = qmax_model_close(handle->model);
        if (code == QMAX_OK) handle->model = nullptr;
    }
    if (code != QMAX_OK) {
        handle->running.store(false);
        return code;
    }
    {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        const auto found = g_handles.find(id);
        if (found != g_handles.end() && found->second == handle) g_handles.erase(found);
    }
    return QMAX_OK;
}

#ifdef QUENDERIN_MAX_TEST_RUNNER
JNIEXPORT jboolean JNICALL
Java_MaxModelTestControl_waitTokenize(JNIEnv*, jclass) {
    fake_model_wait_entered();
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_MaxModelTestControl_releaseTokenize(JNIEnv*, jclass) {
    fake_model_release();
    return JNI_TRUE;
}
#endif

}  // extern "C"
