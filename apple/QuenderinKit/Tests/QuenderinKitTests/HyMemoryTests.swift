import XCTest
@testable import QuenderinKit

final class HyMemoryTests: XCTestCase {
    func testStrictProposalGrammarAndNoThinkPrompt() throws {
        XCTAssertEqual(try HyMemory.parse("{\"memories\":[\"Tea\"]}"), ["Tea"])
        for output in ["{\"memories\":[],\"memories\":[\"x\"]}", "{\"memories\":[],\"extra\":1}", "{\"memories\":[1]}", "{\"memories\":[\"\"]}", "{\"memories\":[]} trailing", "<think>private</think>{\"memories\":[]}", "{\"memories\":[\"x\",]}"] { XCTAssertThrowsError(try HyMemory.parse(output)) }
        let prompt = try HyMemory.prompt("User: I prefer tea.\nAssistant: Understood.")
        XCTAssertTrue(prompt.hasPrefix("<｜hy_begin▁of▁sentence｜>")); XCTAssertTrue(prompt.hasSuffix("<｜hy_Assistant｜><think></think>")); XCTAssertTrue(prompt.contains("<｜reasoning_mode｜>reasoning_effort:no_think<｜hy_User｜>"))
        XCTAssertEqual(prompt.components(separatedBy: "<｜hy_begin▁of▁sentence｜>").count, 2)
        XCTAssertThrowsError(try HyMemory.prompt(String(repeating: "é", count: 4097)))
    }
    func testApprovedStoreIsExplicitIdempotentAndPreservesOtherFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quenderin-hy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HyApprovedMemoryStore(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let selected = HyMemoryProposal(text: "Test fixture preference")
        try await store.save(selected); try await store.save(selected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertThrowsError(try HyMemory.parse("{\"memories\":[\"<think>private</think>\"]}"))
    }
}
