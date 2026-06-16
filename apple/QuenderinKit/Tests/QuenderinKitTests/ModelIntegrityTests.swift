import XCTest
import CryptoKit
@testable import QuenderinKit

/// Guards audit finding C3: a tampered / truncated / wrong-mirror download must be rejected
/// before it is loaded into the engine.
final class ModelIntegrityTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quenderin-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testDetectsGGUFMagic() {
        XCTAssertTrue(ModelIntegrity.hasGGUFMagic(ModelIntegrity.ggufMagic))
        XCTAssertTrue(ModelIntegrity.hasGGUFMagic(Data("GGUF and then some".utf8)))
        XCTAssertFalse(ModelIntegrity.hasGGUFMagic(Data("<htm".utf8)))
        XCTAssertFalse(ModelIntegrity.hasGGUFMagic(Data("GG".utf8)), "too short")
    }

    func testStreamingSha256MatchesCryptoKit() throws {
        let body = ModelIntegrity.ggufMagic + Data("payload".utf8)
        let url = try write("m.gguf", body)
        XCTAssertEqual(try ModelIntegrity.sha256Hex(of: url), hex(body))
    }

    func testVerifyPassesValidGGUFWithCorrectChecksum() throws {
        let body = ModelIntegrity.ggufMagic + Data("payload".utf8)
        let url = try write("m.gguf", body)
        XCTAssertNoThrow(try ModelIntegrity.verify(fileURL: url, expectedSHA256: hex(body)))
    }

    func testVerifyPassesMagicOnlyWhenNoChecksumPinned() throws {
        let url = try write("m.gguf", ModelIntegrity.ggufMagic + Data([1, 2, 3]))
        XCTAssertNoThrow(try ModelIntegrity.verify(fileURL: url, expectedSHA256: nil))
    }

    func testVerifyRejectsNonGGUF() throws {
        let url = try write("oops.html", Data("<!doctype html><title>404</title>".utf8))
        XCTAssertThrowsError(try ModelIntegrity.verify(fileURL: url, expectedSHA256: nil))
    }

    func testVerifyRejectsChecksumMismatch() throws {
        let url = try write("m.gguf", ModelIntegrity.ggufMagic + Data("payload".utf8))
        XCTAssertThrowsError(
            try ModelIntegrity.verify(fileURL: url, expectedSHA256: String(repeating: "f", count: 64))
        )
    }
}
