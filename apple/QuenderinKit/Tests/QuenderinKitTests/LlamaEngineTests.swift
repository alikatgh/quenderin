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
        // Valid metadata reaches the runtime boundary without containing model weights.
        // Both an absent runtime and a linked runtime with no tensors must return
        // .loadFailed. Truncated metadata is rejected earlier by the metadata guard.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quenderin-dummy.gguf")
        func integer(_ value: UInt64, _ width: Int) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func string(_ value: String) -> Data { integer(UInt64(value.utf8.count), 8) + Data(value.utf8) }
        var fixture = Data("GGUF".utf8) + integer(3, 4) + integer(0, 8) + integer(1, 8)
        fixture += string("general.architecture") + integer(8, 4) + string("llama")
        try fixture.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(try GGUFModelMetadata.read(from: tmp).architecture, "llama")

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
