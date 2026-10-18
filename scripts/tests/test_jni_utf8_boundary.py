"""Actual JNI specialist/raw/chat wrappers against a synthetic UTF-8 tokenizer, no weights."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile
import unittest
try:
    from .test_jni_exception_boundary import source_wrapper
except ImportError:  # unittest discover -s scripts/tests
    from test_jni_exception_boundary import source_wrapper

ROOT = Path(__file__).resolve().parents[2]


class JNIUTF8BoundaryTests(unittest.TestCase):
    def test_actual_wrappers_standard_utf8_and_malformed_surrogates(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if not compiler or not shutil.which('javac') or not shutil.which('java'):
            self.skipTest('Host C++ compiler and JDK required')
        def run(args):
            result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-4000:])
            return result.stdout
        if platform.system() == 'Darwin':
            java_home = Path(run(['/usr/libexec/java_home', '-v', '21']).strip())
            suffix, linker, include_os = '.dylib', '-dynamiclib', 'darwin'
        else:
            java_home = Path(shutil.which('javac')).resolve().parents[1]
            suffix, linker, include_os = '.so', '-shared', 'linux'
        fixture = r'''
#include "jni_utf8.h"
#define LOGE(...) ((void)0)
#define LOGI(...) ((void)0)
struct Control { bool cancelled() { return false; } };
struct LlamaHandle { bool beam = false; void* model = nullptr; Control* specialist = nullptr; };
static Control control;
static LlamaHandle normal, specialist{false, nullptr, &control};
static LlamaHandle* as_handle(jlong value) { return value == 1 ? &specialist : &normal; }
static jstring make_jstring(JNIEnv* env, const std::string& text) { return quenderin::jni::java_string(env, text); }
static jstring throw_oom(JNIEnv* env, const char* text) { quenderin::jni::fail(env, "java/lang/OutOfMemoryError", text); return nullptr; }
static jstring throw_generation_failed(JNIEnv* env, const char* text) { quenderin::jni::fail(env, "java/lang/IllegalStateException", text); return nullptr; }
static const std::string expected = "BMP \xE6\xA8\xA1 \xF0\x9F\x98\x80 \xF0\xA0\x80\x80";
static std::string tokenize(const std::string& text) { if (text != expected) throw std::runtime_error("Tokenizer received modified UTF-8"); return text; }
static std::string generate(LlamaHandle*, const std::string& prompt, int, JNIEnv*, jobject, jobject, bool& failed) { failed = false; return tokenize(prompt); }
static std::string buildChatPrompt(void*, const std::string& payload, bool& templated, bool) { templated = true; return tokenize(payload); }
extern "C" {
'''
        for name in ('nativeCompleteHyMemoryStreaming', 'nativeComplete', 'nativeCompleteChatStreaming'):
            fixture += source_wrapper(name) + '\n'
        fixture += r'''
JNIEXPORT jstring JNICALL Java_ai_quenderin_core_LlamaEngine_path(JNIEnv* env, jclass, jstring input) {
    const char* text = quenderin::jni::get_chars(env, input, 16384);
    if (!text) return nullptr;
    auto result = make_jstring(env, tokenize(text)); quenderin::jni::release_chars(text); return result;
}
JNIEXPORT jstring JNICALL Java_ai_quenderin_core_LlamaEngine_badOutput(JNIEnv* env, jclass) { return make_jstring(env, "\xED\xA0\x80"); }
}
'''
        java = r'''
package ai.quenderin.core;
public class LlamaEngine {
    static { System.loadLibrary("utf8fixture"); }
    static native String nativeCompleteHyMemoryStreaming(long h, String prompt, Object sink);
    static native String nativeComplete(long h, String prompt, int max);
    static native String nativeCompleteChatStreaming(long h, String payload, int max, boolean noThink, Object sink);
    static native String path(String path);
    static native String badOutput();
    public static void main(String[] args) {
        String value = "BMP 模 \uD83D\uDE00 \uD840\uDC00";
        if (!value.equals(nativeCompleteHyMemoryStreaming(1, value, null)) ||
            !value.equals(nativeComplete(2, value, 512)) ||
            !value.equals(nativeCompleteChatStreaming(2, value, 512, true, null)) ||
            !value.equals(path(value))) throw new AssertionError("Unicode roundtrip failed");
        for (String invalid : new String[]{"\uD800", "\uDC00", "a\u0000b"}) {
            try { nativeCompleteHyMemoryStreaming(1, invalid, null); throw new AssertionError("Invalid UTF-16 accepted"); }
            catch (IllegalArgumentException expected) { }
        }
        try { badOutput(); throw new AssertionError("Invalid native UTF-8 accepted"); }
        catch (IllegalStateException expected) { }
        System.out.println("PASS: actual JNI wrappers/tokenizer standard Unicode boundary");
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='jni-utf8-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR')) as directory:
            folder = Path(directory); (folder / 'fixture.cpp').write_text(fixture)
            (folder / 'LlamaEngine.java').write_text(java)
            run([compiler, '-std=c++17', '-fPIC', linker, '-I', ROOT / 'android/jni', '-I', java_home / 'include', '-I', java_home / 'include' / include_os, folder / 'fixture.cpp', '-o', folder / ('libutf8fixture' + suffix)])
            run(['javac', '-d', folder, folder / 'LlamaEngine.java'])
            self.assertIn('PASS: actual JNI wrappers', run(['java', '-Xcheck:jni', '-Djava.library.path=' + str(folder), '-cp', folder, 'ai.quenderin.core.LlamaEngine']))

    def test_every_text_and_path_boundary_uses_standard_utf8(self):
        source = (ROOT / 'android/jni/llama_jni.cpp').read_text()
        self.assertNotIn('GetStringUTFChars', source)
        self.assertNotIn('ReleaseStringUTFChars', source)
        self.assertIn('quenderin::jni::get_chars(env, model_path, 16384)', source)
        self.assertIn('if (grammar && !g)', source)


if __name__ == '__main__': unittest.main()
