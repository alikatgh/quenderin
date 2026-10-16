import XCTest
@testable import QuenderinKit

final class GGUFModelMetadataTests: XCTestCase {
    private func integer(_ value: UInt64, _ width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func string(_ value: String) -> Data { integer(UInt64(value.utf8.count), 8) + Data(value.utf8) }

    private func file(_ data: Data) throws -> URL {
        let root = ProcessInfo.processInfo.environment["QUENDERIN_TEST_SCRATCH"] ?? NSTemporaryDirectory()
        let file = URL(fileURLWithPath: root).appendingPathComponent("gguf-metadata-\(UUID().uuidString).gguf")
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private func fixture(architecture: String, split: UInt64 = 1) -> Data {
        var data = Data("GGUF".utf8) + integer(3, 4) + integer(0, 8) + integer(3, 8)
        data += string("general.architecture") + integer(8, 4) + string(architecture)
        data += string("test.strings") + integer(9, 4) + integer(8, 4) + integer(2, 8) + string("a") + string("b")
        data += string("split.count") + integer(2, 4) + integer(split, 2)
        return data
    }

    func testReadsMetadataWithoutTensorAllocationAndRejectsRenamedMuse() throws {
        let metadata = try GGUFModelMetadata.read(from: file(fixture(architecture: "muse-spark", split: 22)))
        XCTAssertEqual(metadata.architecture, "muse-spark")
        XCTAssertEqual(metadata.splitCount, 22)
        let renamed = ModelEntry(id: "unrelated", label: "Tiny", filename: "tiny.gguf", ramGB: 0.01,
                                 sizeLabel: "13 MB", paramsBillions: 1, quantization: "Q2_K",
                                 urlString: "https://example.invalid/tiny.gguf", sha256: nil)
        XCTAssertThrowsError(try metadata.validateForLoad(renamed))
        let split = try GGUFModelMetadata.read(from: file(fixture(architecture: "llama", split: 2)))
        XCTAssertThrowsError(try split.validateForLoad(renamed))
        let single = try GGUFModelMetadata.read(from: file(fixture(architecture: "llama")))
        XCTAssertNoThrow(try single.validateForLoad(renamed))
    }

    func testRejectsTruncatedOversizedAndIncorrectlyTypedMetadata() throws {
        let valid = fixture(architecture: "muse-spark", split: 22)
        for count in [0, 4, 12, 24, valid.count - 1] {
            XCTAssertThrowsError(try GGUFModelMetadata.read(from: file(Data(valid.prefix(count)))))
        }
        let large = Data("GGUF".utf8) + integer(3, 4) + integer(0, 8) + integer(100_001, 8)
        XCTAssertThrowsError(try GGUFModelMetadata.read(from: file(large)))
        var bad = Data("GGUF".utf8)
        for chunk in [integer(3, 4), integer(0, 8), integer(1, 8), string("general.architecture"), integer(4, 4), integer(1, 4)] {
            bad += chunk
        }
        XCTAssertThrowsError(try GGUFModelMetadata.read(from: file(bad)))
    }
}
