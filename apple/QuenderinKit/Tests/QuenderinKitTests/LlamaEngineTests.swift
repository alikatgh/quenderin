import XCTest
@testable import QuenderinKit

/// These verify the *fallback* contract — that LlamaEngine degrades cleanly when
/// llama.cpp is not linked, rather than crashing. The real C inference path
/// cannot be exercised headlessly; it needs the `llama` module + a GGUF model +
/// a device/simulator.
final class LlamaEngineTests: XCTestCase {

    func testGenerateBeforeLoadThrowsModelNotLoaded() async {
        let engine = LlamaEngine()
        do {
            _ = try await engine.generate(prompt: "hi", options: .init())
            XCTFail("expected modelNotLoaded before load()")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .modelNotLoaded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLoadMissingFileThrowsModelFileMissing() async {
        let engine = LlamaEngine()
        let bogus = URL(fileURLWithPath: "/nonexistent/path/model.gguf")
        do {
            try await engine.load(model: ModelCatalog.smallest, at: bogus)
            XCTFail("expected modelFileMissing for a path that does not exist")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .modelFileMissing(path: bogus.path))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLoadFailsCleanlyWhenLlamaNotLinked() async throws {
        // A real file exists, but without the `llama` module load must fail with a
        // clear .loadFailed — never a crash. (Once llama.cpp is linked, an empty
        // .gguf still yields .loadFailed from a null model, so this stays valid.)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quenderin-dummy.gguf")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let engine = LlamaEngine()
        do {
            try await engine.load(model: ModelCatalog.smallest, at: tmp)
            XCTFail("expected load to fail without a real model / linked runtime")
        } catch let error as InferenceError {
            guard case .loadFailed = error else {
                return XCTFail("expected .loadFailed, got \(error)")
            }
        }
        let id = await engine.loadedModelID()
        XCTAssertNil(id, "a failed load must not mark a model as loaded")
    }
}
