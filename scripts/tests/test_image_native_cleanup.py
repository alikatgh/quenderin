"""Compile the actual Swift image adapter and join a deliberately slow synthetic C destructor."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Swift host compiler unavailable')
class ImageNativeCleanupTests(unittest.TestCase):
    def test_native_resources_are_freed_before_success_failure_and_cancel_resume(self):
        with tempfile.TemporaryDirectory(prefix='image-cleanup-') as temporary:
            folder = Path(temporary)
            (folder / 'shim.h').write_text('#include "' + str(ROOT / 'native/diffusion/quenderin_diffusion.h') + '"\nint qd_fixture_active(void);\n')
            (folder / 'module.modulemap').write_text('module QuenderinDiffusion { header "shim.h" export * }\n')
            native = folder / 'stub.c'
            native.write_text(r'''
#include "shim.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
struct quenderin_diffusion_engine { atomic_int cancelled; };
static atomic_int active;
int qd_fixture_active(void) { return atomic_load(&active); }
uint32_t quenderin_diffusion_abi(void) { return 1; }
quenderin_diffusion_engine *quenderin_diffusion_create(void) {
    quenderin_diffusion_engine *engine = calloc(1, sizeof(*engine)); atomic_fetch_add(&active, 1); return engine;
}
quenderin_diffusion_status quenderin_diffusion_destroy(quenderin_diffusion_engine *engine) {
    usleep(100000); free(engine); atomic_fetch_sub(&active, 1); return QUENDERIN_DIFFUSION_OK;
}
quenderin_diffusion_status quenderin_diffusion_cancel(quenderin_diffusion_engine *engine) {
    atomic_store(&engine->cancelled, 1); return QUENDERIN_DIFFUSION_OK;
}
quenderin_diffusion_status quenderin_diffusion_generate(quenderin_diffusion_engine *engine,
    const quenderin_diffusion_request *request, quenderin_diffusion_progress progress, void *user, char *error, size_t size) {
    (void)progress; (void)user; (void)error; (void)size;
    if (!strcmp(request->prompt, "failure")) return QUENDERIN_DIFFUSION_GENERATION_FAILED;
    if (!strcmp(request->prompt, "cancel")) {
        for (int i = 0; i < 1000 && !atomic_load(&engine->cancelled); ++i) usleep(1000);
        return QUENDERIN_DIFFUSION_CANCELLED;
    }
    const unsigned char png[] = {137,80,78,71,13,10,26,10};
    FILE *file = fopen(request->output_path, "wb"); if (!file) return QUENDERIN_DIFFUSION_OUTPUT_FAILED;
    fwrite(png, 1, sizeof(png), file); fclose(file); return QUENDERIN_DIFFUSION_OK;
}
''')
            client = folder / 'client.swift'
            client.write_text(r'''
import Foundation
import QuenderinDiffusion
public struct ImageModel: Sendable {
    struct Component: Sendable { let role: String; let localFilename: String }
    struct Defaults: Sendable { let width = 64; let height = 64; let steps = 1 }
    let components: [Component] = []; let modelKind = 1; let defaults = Defaults()
    func validate() throws {}
}
public struct ImageResourceBudget: Sendable { func blockReason(for model: ImageModel, installing: Bool) -> String? { nil } }
enum ImageGenerationError: Error { case invalid(String) }
enum ImageModelInstaller {
    static func verify(_ model: ImageModel, in directory: URL, cancelled: () -> Bool) throws { if cancelled() { throw CancellationError() } }
}
@main struct Verify {
    static func main() async throws {
        let engine = NativeImageGenerationEngine()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func request(_ prompt: String) -> ImageGenerationRequest {
            ImageGenerationRequest(model: ImageModel(), directory: root, prompt: prompt,
                output: root.appendingPathComponent(prompt + ".png"), seed: 0, budget: ImageResourceBudget())
        }
        _ = try await engine.generate(request("success")) { _ in }
        precondition(qd_fixture_active() == 0, "Success resumed before native destruction")
        do { _ = try await engine.generate(request("failure")) { _ in }; fatalError("Expected failure") } catch {}
        precondition(qd_fixture_active() == 0, "Failure resumed before native destruction")
        let job = Task { try await engine.generate(request("cancel")) { _ in } }
        while qd_fixture_active() == 0 { try await Task.sleep(nanoseconds: 1000000) }
        job.cancel()
        do { _ = try await job.value; fatalError("Expected cancellation") } catch {}
        precondition(qd_fixture_active() == 0, "Cancellation resumed before native destruction")
        print("PASS: native image cleanup joined before continuation")
    }
}
''')
            for args in [
                ['clang', '-std=c11', '-I', folder, '-c', native, '-o', folder / 'stub.o'],
                ['swiftc', '-swift-version', '6', '-module-cache-path', folder / 'module-cache', '-I', folder,
                 ROOT / 'apple/QuenderinKit/Sources/QuenderinKit/ImageGenerationEngine.swift', client,
                 folder / 'stub.o', '-o', folder / 'verify'],
                [folder / 'verify', folder],
            ]:
                result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-5000:])


if __name__ == '__main__':
    unittest.main()
