import XCTest
@testable import QuenderinKit

final class JaisChatTests: XCTestCase {
    func testPrivateReasoningNeverLeaksAcrossTokenBoundaries() {
        for closer in ["</ifm|think>", "</ifm|think_faster>", "</ifm|think_fast>"] {
            let wire = "private reasoning" + closer + "مرحباً world<|ifm|im_end|>hidden next turn"
            for split in 0...wire.count {
                var filter = JaisFinalChannelFilter()
                let text = filter.feed(String(wire.prefix(split)))
                    + filter.feed(String(wire.dropFirst(split))) + filter.finish()
                XCTAssertEqual(text, "مرحباً world", "split \(split)")
            }
        }
    }
    func testIncompleteReasoningIsDiscarded() {
        var filter = JaisFinalChannelFilter()
        XCTAssertEqual(filter.feed("private reasoning</ifm|thi") + filter.finish(), "")
    }
    func testAliasesKeepJaisPolicyAndOlderRuntimeIsBlocked() throws {
        guard let model = ModelCatalog.entry(id: "jais3-0.9b") else { return XCTFail("Missing Jais") }
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        data["id"] = "imported-model"
        let imported = try JSONDecoder().decode(ModelEntry.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertTrue(ModelRuntimeSupport.isJais(imported))
        let fit = MemoryFitness.check(model: imported, totalGB: 256, freeGB: 256,
                                      prismRuntimeAvailable: true, weeklyTextRuntimeAvailable: false)
        XCTAssertFalse(fit.canLoad)
        XCTAssertTrue(fit.message.contains("backport"))
    }
}
