#pragma once
#include <jni.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

// JNI's modified UTF-8 is not the encoding accepted by llama.cpp or local paths.
namespace quenderin::jni {
inline void fail(JNIEnv* env, const char* type, const char* message) noexcept {
    if (env->ExceptionCheck()) return;
    if (auto cls = env->FindClass(type)) { env->ThrowNew(cls, message); env->DeleteLocalRef(cls); }
}
inline std::string utf8(JNIEnv* env, jstring value, size_t maximum) {
    if (env->ExceptionCheck()) throw std::runtime_error("Pending Java exception");
    if (!value) throw std::runtime_error("Missing string");
    const jsize count = env->GetStringLength(value);
    if (count < 0 || size_t(count) > maximum) throw std::runtime_error("Excessive string");
    const jchar* chars = env->GetStringChars(value, nullptr);
    if (!chars) throw std::runtime_error("Cannot read string");
    struct Release { JNIEnv* env; jstring value; const jchar* chars; ~Release() { env->ReleaseStringChars(value, chars); } } release{env, value, chars};
    std::string result;
    for (jsize i = 0; i < count; ++i) {
        uint32_t c = chars[i];
        if (!c) throw std::runtime_error("NUL is unavailable in native strings");
        if (c >= 0xD800 && c <= 0xDBFF) {
            if (++i >= count || chars[i] < 0xDC00 || chars[i] > 0xDFFF) throw std::runtime_error("Unpaired UTF-16 surrogate");
            c = 0x10000 + ((c - 0xD800) << 10) + (chars[i] - 0xDC00);
        } else if (c >= 0xDC00 && c <= 0xDFFF) throw std::runtime_error("Unpaired UTF-16 surrogate");
        if (c < 0x80) result += char(c);
        else if (c < 0x800) { result += char(0xC0 | (c >> 6)); result += char(0x80 | (c & 63)); }
        else if (c < 0x10000) { result += char(0xE0 | (c >> 12)); result += char(0x80 | ((c >> 6) & 63)); result += char(0x80 | (c & 63)); }
        else { result += char(0xF0 | (c >> 18)); result += char(0x80 | ((c >> 12) & 63)); result += char(0x80 | ((c >> 6) & 63)); result += char(0x80 | (c & 63)); }
        if (result.size() > maximum) throw std::runtime_error("Excessive UTF-8 string");
    }
    return result;
}
// C-style ownership keeps cleanup legal even when a token callback left a Java exception pending.
inline const char* get_chars(JNIEnv* env, jstring value, size_t maximum = 1 << 20) noexcept {
    try {
        const auto text = utf8(env, value, maximum);
        auto* copy = static_cast<char*>(std::malloc(text.size() + 1));
        if (!copy) throw std::bad_alloc();
        std::memcpy(copy, text.c_str(), text.size() + 1); return copy;
    } catch (const std::bad_alloc&) { fail(env, "java/lang/OutOfMemoryError", "Cannot allocate UTF-8 string"); }
      catch (...) { fail(env, "java/lang/IllegalArgumentException", "Malformed or excessive UTF-16 string"); }
    return nullptr;
}
inline void release_chars(const char* text) noexcept { std::free(const_cast<char*>(text)); }
inline jstring java_string(JNIEnv* env, const std::string& text) noexcept {
    if (env->ExceptionCheck()) return nullptr;
    try {
        if (text.size() > size_t(std::numeric_limits<jsize>::max())) throw std::runtime_error("Excessive native string");
        std::vector<jchar> result;
        for (size_t i = 0; i < text.size();) {
            const auto first = uint8_t(text[i++]); uint32_t c; size_t extra;
            if (first < 0x80) { c = first; extra = 0; }
            else if (first >= 0xC2 && first <= 0xDF) { c = first & 31; extra = 1; }
            else if (first >= 0xE0 && first <= 0xEF) { c = first & 15; extra = 2; }
            else if (first >= 0xF0 && first <= 0xF4) { c = first & 7; extra = 3; }
            else throw std::runtime_error("Invalid UTF-8 lead");
            if (i + extra > text.size()) throw std::runtime_error("Incomplete UTF-8");
            for (size_t n = 0; n < extra; ++n) { const auto next = uint8_t(text[i++]); if ((next & 0xC0) != 0x80) throw std::runtime_error("Invalid UTF-8 continuation"); c = (c << 6) | (next & 63); }
            if ((extra == 1 && c < 0x80) || (extra == 2 && c < 0x800) || (extra == 3 && c < 0x10000) || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) throw std::runtime_error("Invalid UTF-8 scalar");
            if (c <= 0xFFFF) result.push_back(jchar(c));
            else { c -= 0x10000; result.push_back(jchar(0xD800 | (c >> 10))); result.push_back(jchar(0xDC00 | (c & 1023))); }
        }
        return env->NewString(result.data(), jsize(result.size()));
    } catch (const std::bad_alloc&) { fail(env, "java/lang/OutOfMemoryError", "Cannot allocate Java string"); }
      catch (...) { fail(env, "java/lang/IllegalStateException", "Native runtime returned invalid UTF-8"); }
    return nullptr;
}
} // namespace quenderin::jni
