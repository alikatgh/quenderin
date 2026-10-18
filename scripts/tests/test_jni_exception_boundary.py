"""Compile the actual Hy JNI completion wrapper with a strict pending-exception fixture."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source_wrapper(name):
    text = (ROOT / 'android/jni/llama_jni.cpp').read_text()
    start = text.index('JNIEXPORT jstring JNICALL\nJava_ai_quenderin_core_LlamaEngine_' + name)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


class JNIExceptionBoundaryTests(unittest.TestCase):
    def test_actual_hy_wrapper_preserves_throwing_sink_exception_before_other_jni_calls(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if not compiler:
            self.skipTest('Host C++ compiler unavailable')
        fixture = r'''
#include <stdexcept>
#include <string>
#define JNIEXPORT
#define JNICALL
using jlong = long long;
using jobject = void*;
using jstring = void*;
struct JNIEnv {
    bool pending = false;
    int forbidden = 0, released = 0;
    void ordinary() { if (pending) ++forbidden; }

    bool ExceptionCheck() { return pending; }
    void CallVoidMethod() { ordinary(); pending = true; } // TokenSink throws CancellationException.
};
static JNIEnv* current;
namespace quenderin::jni {
const char* get_chars(JNIEnv* env, jstring) { env->ordinary(); return "prompt"; }
void release_chars(const char*) { ++current->released; }
}
static bool callbackThrows = true;
struct Control { bool cancelled() { current->ordinary(); return false; } };
struct LlamaHandle { Control* specialist; };
static LlamaHandle* as_handle(jlong h) { return reinterpret_cast<LlamaHandle*>(h); }
static jstring throw_generation_failed(JNIEnv* env, const char*) { env->ordinary(); return nullptr; }
static jstring throw_oom(JNIEnv* env, const char*) { env->ordinary(); return nullptr; }
static jstring make_jstring(JNIEnv* env, const std::string&) { env->ordinary(); return reinterpret_cast<jstring>(1); }
static std::string generate(LlamaHandle*, const std::string&, int, JNIEnv* env, jobject, jobject, bool& failed) {
    failed = false; if (callbackThrows) env->CallVoidMethod(); return "answer";
}
'''
        fixture += source_wrapper('nativeCompleteHyMemoryStreaming')
        fixture += r'''
int main() {
    JNIEnv env; current = &env; Control control; LlamaHandle model{&control};
    auto result = Java_ai_quenderin_core_LlamaEngine_nativeCompleteHyMemoryStreaming(&env, nullptr,
        reinterpret_cast<jlong>(&model), reinterpret_cast<jstring>(1), reinterpret_cast<jobject>(1));
    if (result || !env.pending || env.forbidden || env.released != 1) return 1;
    env.pending = false; callbackThrows = false;
    result = Java_ai_quenderin_core_LlamaEngine_nativeCompleteHyMemoryStreaming(&env, nullptr,
        reinterpret_cast<jlong>(&model), reinterpret_cast<jstring>(1), reinterpret_cast<jobject>(1));
    return !result || env.pending || env.forbidden || env.released != 2;
}
'''
        with tempfile.TemporaryDirectory(prefix='jni-exception-fixture-', dir=os.environ.get('TMPDIR')) as directory:
            folder = Path(directory)
            source, executable = folder / 'fixture.cpp', folder / ('fixture.exe' if os.name == 'nt' else 'fixture')
            source.write_text(fixture)
            subprocess.run([compiler, '-std=c++17', '-O0', str(source), '-o', str(executable)], check=True, capture_output=True, timeout=30)
            subprocess.run([str(executable)], check=True, capture_output=True, timeout=10)

    def test_other_completion_wrappers_guard_callback_exceptions_before_result_conversion(self):
        for name in ('nativeComplete', 'nativeCompleteStreaming', 'nativeCompleteChatStreaming', 'nativeCompleteWithGrammar'):
            with self.subTest(name=name):
                wrapper = source_wrapper(name)
                tail = wrapper[wrapper.index('std::string out = generate('):]
                self.assertLess(tail.index('if (env->ExceptionCheck()) return nullptr;'), tail.index('if (failed)'))
                self.assertLess(tail.index('if (env->ExceptionCheck()) return nullptr;'), tail.index('return make_jstring'))


if __name__ == '__main__':
    unittest.main()
