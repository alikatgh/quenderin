#include "quenderin_speech.h"
#include <cstdint>
#include <jni.h>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
quenderin_speech_engine *engine(jlong handle) {
    return reinterpret_cast<quenderin_speech_engine *>(static_cast<uintptr_t>(handle));
}

std::string utf8(JNIEnv *env, jstring input, bool required, size_t limit = 8192) {
    if (!input) { if (required) throw std::runtime_error("Missing required speech parameter."); return ""; }
    const jsize length = env->GetStringLength(input);
    const jchar *chars = env->GetStringChars(input, nullptr);
    if (!chars) throw std::runtime_error("Unable to read JVM string.");
    std::string value;
    value.reserve(static_cast<size_t>(length));
    bool invalid = false;
    for (jsize i = 0; i < length; ++i) {
        uint32_t point = chars[i];
        if (!point) { invalid = true; break; }
        if (point >= 0xd800 && point <= 0xdbff) {
            if (i + 1 >= length || chars[i + 1] < 0xdc00 || chars[i + 1] > 0xdfff) { invalid = true; break; }
            point = 0x10000 + (((point - 0xd800) << 10) | (chars[++i] - 0xdc00));
        } else if (point >= 0xdc00 && point <= 0xdfff) { invalid = true; break; }
        if (point < 0x80) value.push_back(static_cast<char>(point));
        else if (point < 0x800) { value.push_back(static_cast<char>(0xc0 | (point >> 6))); value.push_back(static_cast<char>(0x80 | (point & 63))); }
        else if (point < 0x10000) { value.push_back(static_cast<char>(0xe0 | (point >> 12))); value.push_back(static_cast<char>(0x80 | ((point >> 6) & 63))); value.push_back(static_cast<char>(0x80 | (point & 63))); }
        else { value.push_back(static_cast<char>(0xf0 | (point >> 18))); value.push_back(static_cast<char>(0x80 | ((point >> 12) & 63))); value.push_back(static_cast<char>(0x80 | ((point >> 6) & 63))); value.push_back(static_cast<char>(0x80 | (point & 63))); }
        if (value.size() > limit) { invalid = true; break; }
    }
    env->ReleaseStringChars(input, chars);
    if (invalid) throw std::runtime_error("Speech input text contains invalid Unicode or exceeds size limits.");
    return value;
}
} // namespace

extern "C" JNIEXPORT jint JNICALL Java_ai_quenderin_core_NativeSpeechBridge_abi(JNIEnv *, jclass) {
    return quenderin_speech_abi();
}
extern "C" JNIEXPORT jlong JNICALL Java_ai_quenderin_core_NativeSpeechBridge_create(JNIEnv *, jclass) {
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(quenderin_speech_create()));
}
extern "C" JNIEXPORT jint JNICALL Java_ai_quenderin_core_NativeSpeechBridge_cancel(JNIEnv *, jclass, jlong handle) {
    return quenderin_speech_cancel(engine(handle));
}
extern "C" JNIEXPORT jint JNICALL Java_ai_quenderin_core_NativeSpeechBridge_destroy(JNIEnv *, jclass, jlong handle) {
    return quenderin_speech_destroy(engine(handle));
}

extern "C" JNIEXPORT jbyteArray JNICALL Java_ai_quenderin_core_NativeSpeechBridge_transcribePcm(
    JNIEnv *env, jclass, jlong handle, jstring modelPath, jstring vadPath, jshortArray samples, jint count,
    jstring language, jstring prompt, jobjectArray vocabulary, jint threads, jboolean translate, jboolean timestamps) {
    try {
        if (!samples || count < 1 || count > env->GetArrayLength(samples)) {
            throw std::runtime_error("Invalid audio buffer length.");
        }
        auto model = utf8(env, modelPath, true, 4096);
        auto vad = utf8(env, vadPath, false, 4096);
        auto lang = utf8(env, language, false, 32);
        auto ctx_prompt = utf8(env, prompt, false, 8192);
        std::vector<std::string> terms;
        std::vector<const char *> term_ptrs;
        if (vocabulary) {
            jsize n = env->GetArrayLength(vocabulary);
            if (n > 100) throw std::runtime_error("Speech vocabulary exceeds 100 terms.");
            for (jsize i = 0; i < n; ++i) {
                auto term_obj = static_cast<jstring>(env->GetObjectArrayElement(vocabulary, i));
                auto term = utf8(env, term_obj, true, 256);
                env->DeleteLocalRef(term_obj);
                terms.push_back(std::move(term));
            }
            for (const auto &t : terms) term_ptrs.push_back(t.c_str());
        }
        std::vector<float> pcm(static_cast<size_t>(count));
        std::vector<jshort> page(2048);
        for (jint i = 0; i < count; i += 2048) {
            jint chunk = std::min<jint>(2048, count - i);
            env->GetShortArrayRegion(samples, i, chunk, page.data());
            if (env->ExceptionCheck()) return nullptr;
            for (jint j = 0; j < chunk; ++j) pcm[static_cast<size_t>(i + j)] = page[static_cast<size_t>(j)] / 32768.0f;
        }
        quenderin_speech_request req{};
        req.abi_version = QUENDERIN_SPEECH_ABI;
        req.struct_size = sizeof(req);
        req.model_path = model.c_str();
        req.vad_path = vad.empty() ? nullptr : vad.c_str();
        req.pcm_f32 = pcm.data();
        req.pcm_samples = pcm.size();
        req.sample_rate = 16000;
        req.language = lang.empty() ? nullptr : lang.c_str();
        req.prompt = ctx_prompt.empty() ? nullptr : ctx_prompt.c_str();
        req.vocabulary = term_ptrs.empty() ? nullptr : term_ptrs.data();
        req.vocabulary_count = static_cast<uint32_t>(term_ptrs.size());
        req.threads = static_cast<uint32_t>(std::clamp<int>(threads, 1, 8));
        req.translate = translate == JNI_TRUE;
        req.timestamps = timestamps == JNI_TRUE;

        quenderin_speech_result result{};
        char error[512]{};
        auto status = quenderin_speech_transcribe(engine(handle), &req, &result, error, sizeof(error));
        if (status != QUENDERIN_SPEECH_OK) {
            quenderin_speech_result_free(&result);
            throw std::runtime_error(*error ? error : "Local speech transcription failed.");
        }
        std::string text = result.text ? result.text : "";
        quenderin_speech_result_free(&result);
        auto out = env->NewByteArray(static_cast<jsize>(text.size()));
        if (out && !text.empty()) {
            env->SetByteArrayRegion(out, 0, static_cast<jsize>(text.size()),
                                    reinterpret_cast<const jbyte *>(text.data()));
        }
        return out;
    } catch (...) {
        return nullptr;
    }
}
