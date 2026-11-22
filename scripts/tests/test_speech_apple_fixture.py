"""Compile the real Swift SpeechFormatting + NativeSpeechEngine adapters and verify cleanup/formatting."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Swift host compiler unavailable')
class SpeechAppleFixtureTests(unittest.TestCase):
    def test_native_speech_cleanup_formatting_and_cancellation(self):
        with tempfile.TemporaryDirectory(prefix='speech-apple-') as temporary:
            folder = Path(temporary)
            (folder / 'shim.h').write_text('#include "' + str(ROOT / 'native/speech/quenderin_speech.h') + '"\nint qs_fixture_active(void);\n')
            (folder / 'module.modulemap').write_text('module QuenderinSpeech { header "shim.h" export * }\n')
            native = folder / 'stub.c'
            native.write_text(r'''
#include "shim.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct quenderin_speech_engine { atomic_int cancelled; };
static atomic_int active;

int qs_fixture_active(void) { return atomic_load(&active); }
uint32_t quenderin_speech_abi(void) { return 1; }
const char *quenderin_speech_revision(void) { return "60bed89dab84f7c1fddc3a17ad7fa8a27ddfba19"; }

quenderin_speech_engine *quenderin_speech_create(void) {
    quenderin_speech_engine *engine = calloc(1, sizeof(*engine));
    atomic_fetch_add(&active, 1);
    return engine;
}
quenderin_speech_status quenderin_speech_destroy(quenderin_speech_engine *engine) {
    usleep(80000);
    free(engine);
    atomic_fetch_sub(&active, 1);
    return QUENDERIN_SPEECH_OK;
}
quenderin_speech_status quenderin_speech_cancel(quenderin_speech_engine *engine) {
    atomic_store(&engine->cancelled, 1);
    return QUENDERIN_SPEECH_OK;
}
quenderin_speech_status quenderin_speech_validate(const quenderin_speech_request *r, char *error, size_t size) {
    (void)r; (void)error; (void)size;
    return QUENDERIN_SPEECH_OK;
}
void quenderin_speech_result_free(quenderin_speech_result *res) {
    if (!res) return;
    free(res->text); free(res->language); free(res->backend); free(res->segments_json);
    memset(res, 0, sizeof(*res));
}
quenderin_speech_status quenderin_speech_transcribe(
    quenderin_speech_engine *engine,
    const quenderin_speech_request *request,
    quenderin_speech_result *result,
    char *error,
    size_t error_size
) {
    if (request->prompt && !strcmp(request->prompt, "failure")) {
        snprintf(error, error_size, "synthetic failure");
        return QUENDERIN_SPEECH_TRANSCRIBE_FAILED;
    }
    if (request->prompt && !strcmp(request->prompt, "cancel")) {
        for (int i = 0; i < 1000 && !atomic_load(&engine->cancelled); ++i) usleep(1000);
        result->aborted = true;
        return QUENDERIN_SPEECH_CANCELLED;
    }
    result->text = strdup("uh check quanderin comma please");
    result->language = strdup("en");
    result->backend = strdup("cpu-fixture");
    result->segments_json = strdup("[{\"startMs\":0,\"endMs\":40,\"text\":\"uh check quanderin comma please\"}]");
    result->duration_ms = 40;
    return QUENDERIN_SPEECH_OK;
}
''')
            client = folder / 'client.swift'
            client.write_text(r'''
import Foundation
import QuenderinSpeech

public struct SpeechVadModel: Codable, Sendable, Equatable { let localFilename: String; func validate() throws {} }
public struct SpeechModel: Codable, Sendable, Equatable {
    let id = "parakeet_unified_en"
    let localFilename: String? = "parakeet.gguf"
    func validate() throws {}
}
enum SpeechEngineError: Error { case invalid(String); case cancelled }
enum SpeechModelInstaller {
    static func verify(_ model: SpeechModel, in directory: URL, vad: SpeechVadModel?, cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }
}

@main struct VerifySpeech {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let wav = root.appendingPathComponent("input.wav")
        try Data(repeating: 0, count: 64).write(to: wav)
        let engine = NativeSpeechEngine()
        precondition(engine.available, "Speech ABI mismatch")

        let formatting = SpeechFormattingOptions(
            vocabulary: [SpeechVocabularyTerm(term: "Quenderin", phoneticHints: ["quanderin"])],
            removeFillerWords: true,
            spokenPunctuation: true
        )
        let ok = try await engine.transcribe(SpeechTranscriptionRequest(
            model: SpeechModel(), directory: root, wavURL: wav, formatting: formatting
        ))
        precondition(qs_fixture_active() == 0, "Success resumed before native destruction")
        precondition(ok.text == "check Quenderin, please", "Unexpected formatted text: \(ok.text)")
        precondition(ok.segments.count == 1)

        do {
            _ = try await engine.transcribe(SpeechTranscriptionRequest(
                model: SpeechModel(), directory: root, wavURL: wav, prompt: "failure"
            ))
            fatalError("Expected failure")
        } catch {}
        precondition(qs_fixture_active() == 0, "Failure resumed before native destruction")

        let job = Task {
            try await engine.transcribe(SpeechTranscriptionRequest(
                model: SpeechModel(), directory: root, wavURL: wav, prompt: "cancel"
            ))
        }
        while qs_fixture_active() == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        job.cancel()
        do {
            _ = try await job.value
            fatalError("Expected cancellation")
        } catch {}
        precondition(qs_fixture_active() == 0, "Cancellation resumed before native destruction")

        let listOut = SpokenLists.apply(to: "first check builds second verify docs")
        precondition(listOut == "1. check builds\n2. verify docs", "Unexpected list output: \(listOut)")
        precondition(FrenchSpacing.apply(to: "salut !") == "salut\u{202F}!")
        print("PASS: Apple speech formatting, cancellation, and cleanup verified")
    }
}
''')
            for args in [
                ['clang', '-std=c11', '-I', folder, '-c', native, '-o', folder / 'stub.o'],
                ['swiftc', '-swift-version', '6', '-module-cache-path', folder / 'module-cache', '-I', folder,
                 ROOT / 'apple/QuenderinKit/Sources/QuenderinKit/SpeechFormatting.swift',
                 ROOT / 'apple/QuenderinKit/Sources/QuenderinKit/NativeSpeechEngine.swift',
                 client, folder / 'stub.o', '-o', folder / 'verify'],
                [folder / 'verify', folder],
            ]:
                result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-5000:])


if __name__ == '__main__':
    unittest.main()
