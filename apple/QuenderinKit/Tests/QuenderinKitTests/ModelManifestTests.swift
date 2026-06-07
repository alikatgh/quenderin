import XCTest
@testable import QuenderinKit

final class ModelManifestTests: XCTestCase {

    func testCurrentManifestWrapsCatalog() {
        XCTAssertEqual(ModelManifest.current.version, 1)
        XCTAssertEqual(ModelManifest.current.models, ModelCatalog.models)
    }

    func testRoundTripsThroughJSON() throws {
        let data = try ModelManifest.current.jsonData()
        let decoded = try ModelManifest.decode(from: data)
        XCTAssertEqual(decoded, ModelManifest.current)
        XCTAssertEqual(decoded.models.count, 11)
    }

    func testJSONIsStableAndContainsCatalogIDs() throws {
        let json = String(decoding: try ModelManifest.current.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("llama3-8b"))
        XCTAssertTrue(json.contains("llama32-1b-q2"))
    }

    /// The encoding must use the canonical cross-platform keys (`ramGb`, `url`) so the
    /// JSON iOS emits/consumes matches the desktop-generated manifest.
    func testUsesCanonicalSchemaKeys() throws {
        let json = String(decoding: try ModelManifest.current.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"ramGb\""), "expected canonical key ramGb")
        XCTAssertTrue(json.contains("\"url\""), "expected canonical key url")
        XCTAssertFalse(json.contains("\"ramGB\""), "must not use the old Swift-only key ramGB")
        XCTAssertFalse(json.contains("\"urlString\""), "must not use the old Swift-only key urlString")
    }

    /// iOS decodes the EXACT committed `shared/model-catalog.json`, and the
    /// recommendation-affecting fields match the embedded catalog — proving the manifest
    /// is genuinely consumable, not just round-trippable.
    func testDecodesCommittedCanonicalManifest() throws {
        let manifest = try ModelManifest.decode(from: Data(contentsOf: canonicalManifestURL()))
        XCTAssertEqual(Set(manifest.models.map(\.id)), Set(ModelCatalog.models.map(\.id)))
        for entry in manifest.models {
            let local = ModelCatalog.entry(id: entry.id)
            XCTAssertEqual(local?.paramsBillions, entry.paramsBillions, "params drift for \(entry.id)")
            XCTAssertEqual(local?.quantization, entry.quantization, "quant drift for \(entry.id)")
        }
    }

    /// Repo-root-relative path to the canonical manifest (via the test file's location).
    private func canonicalManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)               // …/Tests/QuenderinKitTests/ModelManifestTests.swift
            .deletingLastPathComponent()              // QuenderinKitTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // QuenderinKit
            .deletingLastPathComponent()              // apple
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("shared/model-catalog.json")
    }
}
