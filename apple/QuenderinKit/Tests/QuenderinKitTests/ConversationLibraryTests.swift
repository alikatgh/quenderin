import XCTest
@testable import QuenderinKit

final class ConversationLibraryTests: XCTestCase {
    private func s(_ id: String, _ title: String, _ t: Int64) -> ConversationSummary {
        ConversationSummary(id: id, title: title, updatedAt: t)
    }

    func testListIsMostRecentFirstWithStableTieBreak() {
        let lib = ConversationLibrary()
        lib.upsert(s("a", "A", 100))
        lib.upsert(s("c", "C", 300))
        lib.upsert(s("b", "B", 300))   // ties with c on time → id breaks the tie
        XCTAssertEqual(lib.list().map(\.id), ["b", "c", "a"])
    }

    func testUpsertReplacesById() {
        let lib = ConversationLibrary()
        lib.upsert(s("a", "first", 100))
        lib.upsert(s("a", "renamed", 200))
        XCTAssertEqual(lib.count, 1)
        XCTAssertEqual(lib.get("a")?.title, "renamed")
        XCTAssertEqual(lib.get("a")?.updatedAt, 200)
    }

    func testRemove() {
        let lib = ConversationLibrary()
        lib.upsert(s("a", "A", 1))
        XCTAssertTrue(lib.remove("a"))
        XCTAssertFalse(lib.remove("a"), "removing a missing id is a no-op")
        XCTAssertNil(lib.get("a"))
    }

    func testSnapshotRestoreRoundTrips() {
        let lib = ConversationLibrary()
        lib.upsert(s("a", "A", 1))
        lib.upsert(s("b", "B", 2))
        let restored = ConversationLibrary(lib.snapshot())
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.list().map(\.id), ["b", "a"])
    }

    func testTitleDerivation() {
        XCTAssertEqual(ConversationLibrary.title(fromFirstUserMessage: nil), "New conversation")
        XCTAssertEqual(ConversationLibrary.title(fromFirstUserMessage: "   "), "New conversation")
        XCTAssertEqual(ConversationLibrary.title(fromFirstUserMessage: "  hello   there  "), "hello there")
        let long = String(repeating: "x", count: 60)
        let title = ConversationLibrary.title(fromFirstUserMessage: long)
        XCTAssertEqual(title.count, 41, "40 chars + the ellipsis")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    /// Truncation is by CODE POINT, so an emoji title cuts at the same point as Kotlin's
    /// offsetByCodePoints (cross-platform parity) and never splits a surrogate pair.
    func testTitleTruncatesByCodePointForParity() {
        let emoji = "😀" + String(repeating: "a", count: 45)   // 46 code points
        XCTAssertEqual(
            ConversationLibrary.title(fromFirstUserMessage: emoji),
            "😀" + String(repeating: "a", count: 39) + "…")     // 40 code points + ellipsis
    }
}
