"""Execute actual locked addon cancellation edits with tiny host-only fixtures."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'scripts/tests/fixtures/node-llama-cpp-3.19.1'
PATCH = ROOT / 'scripts/patches/node-llama-cpp-3.19.1-prism-e8fd209.json'

def patched(name):
    entry = next(e for e in json.loads(PATCH.read_text())['files'] if e['path'].endswith('/' + name))
    original = (FIXTURES / name).read_text()
    assert hashlib.sha256(original.encode()).hexdigest() == entry['beforeSha256']
    text = original
    for edit in entry['replacements']:
        assert text.count(edit['before']) == 1
        text = text.replace(edit['before'], edit['after'], 1)
    assert hashlib.sha256(text.encode()).hexdigest() == entry['afterSha256']
    return text

def callbacks():
    text = patched('AddonContext.cpp')
    start = text.index('static bool quenderinContextAbortCallback(')
    return text[start:text.index('static uint64_t calculateBatchMemorySize', start)]

class NodeContextAbortTests(unittest.TestCase):
    def test_actual_atomic_callbacks_stop_a_running_worker_before_any_output(self):
        compiler = shutil.which('clang++') or shutil.which('g++')
        self.assertIsNotNone(compiler, 'C++17 compiler required')
        header = patched('AddonContext.h')
        self.assertIn('llama_context* ctx = nullptr;', header)
        atomic = re.search(r'        std::atomic<bool> quenderinAbortRequested\{false\};', header).group(0)
        source = patched('AddonContext.cpp')
        request = re.search(r'quenderinAbortRequested.store\(true, std::memory_order_relaxed\);', source).group(0)
        reset = re.search(r'quenderinAbortRequested.store\(false, std::memory_order_relaxed\);', source).group(0)
        fixture = '''#include <atomic>
#include <cassert>
#include <thread>
struct ggml_tensor;
struct AddonContext {
''' + atomic + '''
void request() { ''' + request + ''' }
void reset() { ''' + reset + ''' }
};
''' + callbacks() + '''
int main() {
    AddonContext context;
    assert(!quenderinContextAbortCallback(&context));
    assert(quenderinContextEvalCallback(nullptr, false, &context));
    std::atomic<bool> entered{false}, output{false};
    std::thread worker([&] {
        entered.store(true);
        // Synthetic CPU graph loop calls the exact compiled production callback.
        while (!quenderinContextAbortCallback(&context)) std::this_thread::yield();
        assert(!output.load());
    });
    while (!entered.load()) std::this_thread::yield();
    context.request(); worker.join();
    assert(quenderinContextAbortCallback(&context));
    assert(quenderinContextEvalCallback(nullptr, true, &context));
    assert(!quenderinContextEvalCallback(nullptr, false, &context));
    context.reset();
    assert(!quenderinContextAbortCallback(&context));
    assert(quenderinContextEvalCallback(nullptr, false, &context));
}
'''
        with tempfile.TemporaryDirectory(prefix='node-context-abort-') as directory:
            binary = Path(directory)/'callbacks'
            result = subprocess.run([compiler, '-std=c++17', '-O0', '-pthread', '-x', 'c++', '-', '-o', str(binary)], input=fixture, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr[-8000:])
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_actual_js_init_installs_listener_under_lock_and_releases_it_on_all_paths(self):
        text = patched('LlamaContext.js')
        start = text.index('                const initLock = await acquireLock(')
        block = text[start:text.index('                const memoryBreakdown', start)]
        cleanup = text[text.index('            catch (error) {\n                await context.dispose();'):]
        cleanup = cleanup[:cleanup.index('            finally {')]
        script = r'''
import assert from 'node:assert/strict';
const run = new (Object.getPrototypeOf(async function(){}).constructor)('context','createSignal','acquireLock','_model','LlamaLocks',
    'try {\n' + BLOCK + '\n}\n' + CLEANUP);
const model = {_llama: {_memoryLock: {}}}, locks = {addonInit: {}};
function fixture(pending = false) {
    const controller = new AbortController(), state = {held: false, requests: 0, resets: 0, disposed: 0, releases: 0, entered: 0};
    let rejectInit;
    const context = {_ctx: {
        resetQuenderinAbort() { assert(state.held); state.resets++; },
        requestQuenderinAbort() { assert(state.held); state.requests++; rejectInit?.(new Error('native abort')); },
        async init() { assert(state.held); state.entered++; if (pending) return new Promise((_, reject) => {rejectInit = reject;}); return true; }
    }, async dispose() { state.disposed++; }};
    const acquireLock = async () => { state.held = true; return {dispose() { assert(state.held); state.held = false; state.releases++; }}; };
    return {controller, state, context, acquireLock};
}
{
    const f = fixture(true), reason = new Error('stop warmup');
    const running = run(f.context, f.controller.signal, f.acquireLock, model, locks);
    await Promise.resolve(); await Promise.resolve();
    assert.equal(f.state.entered, 1); f.controller.abort(reason);
    await assert.rejects(running, error => error === reason);
    assert.equal(f.state.requests, 1); assert.equal(f.state.releases, 1); assert.equal(f.state.disposed, 1);
}
{
    const f = fixture(), request = f.context._ctx.requestQuenderinAbort.bind(f.context._ctx);
    await run(f.context, f.controller.signal, f.acquireLock, model, locks);
    f.controller.abort(); assert.equal(f.state.requests, 0); assert.equal(f.state.disposed, 0); assert.equal(f.state.releases, 1);
}
{
    const f = fixture(); let unlock;
    const gate = new Promise(resolve => { unlock = resolve; });
    const running = run(f.context, f.controller.signal, async () => { await gate; return f.acquireLock(); }, model, locks);
    const reason = new Error('cancel while queued for init'); f.controller.abort(reason); unlock();
    await assert.rejects(running, error => error === reason);
    assert.equal(f.state.entered, 0); assert.equal(f.state.releases, 1); assert.equal(f.state.disposed, 1); assert.equal(f.state.requests, 1);
}
console.log('Actual patched JS initialization cancellation/cleanup passed');
'''.replace('BLOCK', json.dumps(block)).replace('CLEANUP', json.dumps(cleanup))
        result = subprocess.run(['node', '--input-type=module', '-'], input=script, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr[-8000:])

    def test_atomic_napi_methods_compile_with_the_real_node_addon_headers(self):
        compiler = shutil.which('clang++') or shutil.which('g++')
        self.assertIsNotNone(compiler, 'C++17 compiler required')
        napi = ROOT/'node_modules/node-addon-api'
        api = ROOT/'node_modules/node-api-headers/include'
        self.assertTrue((napi/'napi.h').is_file() and (api/'node_api.h').is_file(), 'Locked Node headers required')
        source = patched('AddonContext.cpp')
        start = source.index('uint32_t AddonContext::ContextAbortRuntimeABI()')
        methods = source[start:source.index('Napi::Value AddonContext::Init(', start)]
        fixture = '''#include <atomic>
#include "napi.h"
class AddonContext : public Napi::ObjectWrap<AddonContext> {
public:
    AddonContext(const Napi::CallbackInfo & info) : Napi::ObjectWrap<AddonContext>(info) {}
    std::atomic<bool> quenderinAbortRequested{false};
    static uint32_t ContextAbortRuntimeABI();
    Napi::Value GetQuenderinContextAbortABI(const Napi::CallbackInfo&);
    Napi::Value RequestQuenderinAbort(const Napi::CallbackInfo&);
    Napi::Value ResetQuenderinAbort(const Napi::CallbackInfo&);
};
''' + methods
        result = subprocess.run([compiler, '-std=c++17', '-fsyntax-only', '-DNAPI_CPP_EXCEPTIONS', '-I'+str(napi), '-I'+str(api), '-x', 'c++', '-'], input=fixture, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr[-8000:])

if __name__ == '__main__': unittest.main()
