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
}
