import XCTest
@testable import QuenderinKit

/// Drives the **real** `LlamaEngine` actor end to end — load a GGUF, stream tokens —
/// against a linked llama.cpp. This is the committed regression guard for the
/// on-device inference path (the rest of `LlamaEngineTests` only covers the clean
/// *fallback*).
///
/// It is **skipped by default** so `swift test` stays green with zero setup. To run it:
///
///   QUENDERIN_LLAMA_DIR=/abs/llama.cpp \      # build the `llama` module (see Package.swift)
///   QUENDERIN_LLAMA_MODEL=/abs/model.gguf \   # any small GGUF
///   swift test --filter LlamaEngineRealInferenceTests
///
/// `apple/verify-llama-link.sh` wires both up automatically.
final class LlamaEngineRealInferenceTests: XCTestCase {

    func testRealModelLoadsAndGenerates() async throws {
        let modelPath = ProcessInfo.processInfo.environment["QUENDERIN_LLAMA_MODEL"]
        try XCTSkipIf(
            modelPath?.isEmpty != false,
            "set QUENDERIN_LLAMA_MODEL=/path/to/model.gguf (and build with QUENDERIN_LLAMA_DIR) to run real inference"
        )
        let url = URL(fileURLWithPath: modelPath!)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "QUENDERIN_LLAMA_MODEL does not exist: \(url.path)"
        )

        let engine = LlamaEngine()
        do {
            try await engine.load(model: ModelCatalog.smallest, at: url)
        } catch let InferenceError.loadFailed(reason) where reason.contains("not linked") {
            throw XCTSkip("llama.cpp not linked — rebuild with QUENDERIN_LLAMA_DIR set. (\(reason))")
        }

        let loadedID = await engine.loadedModelID()
        XCTAssertNotNil(loadedID, "a successful load must report a loaded model id")

        let reply = try await engine.complete(
            prompt: "<|im_start|>user\nIn one short sentence, why is the sky blue?<|im_end|>\n<|im_start|>assistant\n",
            options: .init(maxTokens: 48, temperature: 0.4)
        )
        XCTAssertFalse(
            reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "real on-device inference must produce non-empty output"
        )

        await engine.unload()
        let afterUnload = await engine.loadedModelID()
        XCTAssertNil(afterUnload, "unload must clear the loaded model")
    }
}
