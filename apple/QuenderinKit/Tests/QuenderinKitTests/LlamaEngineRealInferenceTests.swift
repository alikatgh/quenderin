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

    // MARK: - KV-cache reuse (the chat-efficiency change) — correctness + timing on real llama.cpp

    private func realModelURL() throws -> URL {
        let modelPath = ProcessInfo.processInfo.environment["QUENDERIN_LLAMA_MODEL"]
        try XCTSkipIf(modelPath?.isEmpty != false,
                      "set QUENDERIN_LLAMA_MODEL=/path/to/model.gguf (+ QUENDERIN_LLAMA_DIR) to run")
        let url = URL(fileURLWithPath: modelPath!)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "model not found: \(url.path)")
        return url
    }

    private func load(_ engine: LlamaEngine, _ url: URL) async throws {
        do { try await engine.load(model: ModelCatalog.smallest, at: url) }
        catch let InferenceError.loadFailed(reason) where reason.contains("not linked") { throw XCTSkip(reason) }
    }

    /// The output of an incremental (KV-reused) 2nd turn must EQUAL a from-scratch full prefill of the
    /// same prompt. Greedy (temperature 0) makes generation deterministic, so any divergence is a real
    /// KV-reuse bug — the on-real-llama validation the `perf(engine): reuse the KV cache` change owed.
    func testKVCacheReuseOutputMatchesFullPrefill() async throws {
        let url = try realModelURL()
        let greedy = GenerationOptions(maxTokens: 24, temperature: 0)

        // Persistent engine: turn 1, then turn 2 whose prompt is (turn-1 prompt + its reply + a new line)
        // — so turn 2 goes through the KV-reuse path.
        let p1 = "User: Name one primary color.\nAssistant:"
        let engineA = LlamaEngine()
        try await load(engineA, url)
        let r1 = try await engineA.complete(prompt: p1, options: greedy)
        XCTAssertFalse(r1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "turn 1 must produce output")
        let p2 = p1 + r1 + "\nUser: Name a different one.\nAssistant:"
        let a2 = try await engineA.complete(prompt: p2, options: greedy)

        // Fresh engine: prefills p2 from an empty KV cache (no reuse) — the ground truth.
        let engineB = LlamaEngine()
        try await load(engineB, url)
        let b2 = try await engineB.complete(prompt: p2, options: greedy)

        XCTAssertEqual(a2, b2, "incremental KV-reuse output must be identical to a from-scratch full prefill")
        await engineA.unload(); await engineB.unload()
    }

    /// The acid test for the **context-shift** path (perf/kv-context-shift): drive a chat whose prompt
    /// evolves by DROPPING its oldest turn from the front (as `ConversationContext` does once the budget
    /// fills), then assert that the KV-reused reply is byte-identical to a from-scratch full prefill of the
    /// same prompt. Because a front-drop diverges right after the shared prefix, this exercises
    /// `llama_memory_seq_rm` + `llama_memory_seq_add` (evict the dropped middle, RoPE-shift the survivors) —
    /// the exact mechanism whose correctness needed validation on real llama.cpp. Greedy (temp 0) makes any
    /// divergence a real bug, not sampling noise.
    func testContextShiftOutputMatchesFullPrefill() async throws {
        let url = try realModelURL()
        let greedy = GenerationOptions(maxTokens: 24, temperature: 0)

        // Build a stable system-prefixed prompt, generate a few turns to fill the cache, then form the
        // NEXT prompt by dropping the oldest user/assistant turn — so the cache holds `sys + t1 + t2`
        // while the new prompt is `sys + t2 + t3`: a front-drop that must go through the context-shift.
        let sys = "System: You are a terse assistant.\n"
        let t1 = "User: Name a primary color.\nAssistant: Red.\n"
        let t2 = "User: Name a fruit.\nAssistant: Apple.\n"
        let t3 = "User: Name a country.\nAssistant:"

        // Persistent engine: prime the cache with `sys + t1 + t2 + <a partial turn>`, then ask `sys + t2 + t3`.
        let engineA = LlamaEngine()
        try await load(engineA, url)
        _ = try await engineA.complete(prompt: sys + t1 + t2 + "User: Warm up.\nAssistant:", options: greedy)
        let shifted = sys + t2 + t3                       // oldest turn (t1) dropped from the front
        let a = try await engineA.complete(prompt: shifted, options: greedy)

        // Fresh engine: same prompt from an empty cache — the ground truth (no reuse, no shift).
        let engineB = LlamaEngine()
        try await load(engineB, url)
        let b = try await engineB.complete(prompt: shifted, options: greedy)

        XCTAssertEqual(a, b, "context-shift (front-drop) output must equal a from-scratch full prefill")
        await engineA.unload(); await engineB.unload()
    }

    /// Drives a multi-turn chat on ONE persistent engine (the real product path) and prints per-turn wall
    /// time. With KV reuse, later turns re-decode only the new tokens, so time-to-first-token should stay
    /// roughly flat instead of climbing with conversation length. Asserts every turn stays coherent.
    func testMultiTurnChatStaysCoherentAndPrintsTiming() async throws {
        let url = try realModelURL()
        let engine = LlamaEngine()
        try await load(engine, url)

        let userLines = ["Say hello in one word.", "Now in French.", "And in Spanish.", "Thank you!"]
        var prompt = ""
        for (i, line) in userLines.enumerated() {
            prompt += "User: \(line)\nAssistant:"
            let start = Date()
            let reply = try await engine.complete(prompt: prompt, options: .init(maxTokens: 24, temperature: 0))
            let ms = Date().timeIntervalSince(start) * 1000
            print(String(format: "  [KV-reuse] turn %d (%d-char prompt): %.0f ms — %@",
                         i + 1, prompt.count, ms, reply.prefix(40).replacingOccurrences(of: "\n", with: " ")))
            XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "turn \(i + 1) must reply")
            prompt += reply + "\n"
        }
        await engine.unload()
    }
}
