// The only vision JNI layer: links the existing Prism llama/ggml runtime once.
#include <jni.h>
#include "jni_utf8.h"
#include "quenderin_vision.h"
#include "ggml-backend.h"
#include <cstdint>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
quenderin_vision* handle(jlong value) { return reinterpret_cast<quenderin_vision*>(value); }
void fail(JNIEnv* env, const char* message) {
    if (env->ExceptionCheck()) return;
    if (auto cls = env->FindClass("java/lang/IllegalStateException")) env->ThrowNew(cls, message);
}
using quenderin::jni::utf8;
using quenderin::jni::java_string;
struct Output { std::string text; bool invalid = false; };
int output(const char* bytes, size_t count, void* user) {
    auto& value = *static_cast<Output*>(user);
    if (!bytes || count > 65536 || value.text.size() > 65536 - count) { value.invalid = true; return 0; }
    try { value.text.append(bytes, count); return 1; } catch (...) { value.invalid = true; return 0; }
}
}
extern "C" {
JNIEXPORT jstring JNICALL Java_ai_quenderin_core_NativeVisionEngine_nativeIdentity(JNIEnv* env, jclass) {
    const auto* revision = quenderin_vision_runtime_revision(); const auto* digest = quenderin_vision_patch_sha256();
    if (!revision || !digest) return nullptr;
    try { return java_string(env, std::to_string(quenderin_vision_runtime_abi()) + ":" + revision + ":" + digest); }
    catch (...) { fail(env, "Vision runtime identity is invalid"); return nullptr; }
}
JNIEXPORT jlong JNICALL Java_ai_quenderin_core_NativeVisionEngine_nativeCreate(JNIEnv* env, jobject, jstring directory) {
    try {
        const auto path = utf8(env, directory, 16384);
        static std::once_flag variants;
        std::call_once(variants, [&] { if (!path.empty()) ggml_backend_load_all_from_path(path.c_str()); });
        return reinterpret_cast<jlong>(quenderin_vision_create());
    } catch (...) { fail(env, "Unable to initialize native vision"); return 0; }
}
JNIEXPORT void JNICALL Java_ai_quenderin_core_NativeVisionEngine_nativeLoad(JNIEnv* env, jobject, jlong value, jstring model, jstring main, jstring projector) {
    try {
        if (!value) throw std::runtime_error("No vision handle");
        const auto id = utf8(env, model, 128), model_path = utf8(env, main, 16384), projector_path = utf8(env, projector, 16384);
        quenderin_vision_load_options options{1, id.c_str(), model_path.c_str(), projector_path.c_str(), 4096, 8};
        if (quenderin_vision_load(handle(value), &options)) throw std::runtime_error(quenderin_vision_last_error(handle(value)));
    } catch (const std::exception& error) { fail(env, error.what()); } catch (...) { fail(env, "Native vision load failed"); }
}
JNIEXPORT jstring JNICALL Java_ai_quenderin_core_NativeVisionEngine_nativeGenerate(JNIEnv* env, jobject, jlong value, jstring image, jstring question) {
    try {
        if (!value) throw std::runtime_error("No vision handle");
        const auto image_path = utf8(env, image, 16384), prompt = utf8(env, question, 32768);
        quenderin_vision_request request{1, image_path.c_str(), prompt.c_str(), 512}; Output final;
        if (quenderin_vision_generate(handle(value), &request, output, &final) || final.invalid || final.text.empty() || quenderin_vision_generated_tokens(handle(value)) > 512)
            throw std::runtime_error(quenderin_vision_last_error(handle(value)));
        return java_string(env, final.text);
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; } catch (...) { fail(env, "Native vision generation failed"); return nullptr; }
}
JNIEXPORT void JNICALL Java_ai_quenderin_core_NativeVisionEngine_nativeCancel(JNIEnv*, jobject, jlong value) { if (value) quenderin_vision_cancel(handle(value)); }
JNIEXPORT void JNICALL Java_ai_quenderin_core_NativeVisionEngine_nativeFree(JNIEnv*, jobject, jlong value) { if (value) quenderin_vision_free(handle(value)); }
}
