import XCTest
@testable import QuenderinKit

/// Per-conversation appearance overrides: present ⇄ absent must round-trip cleanly, and
/// "all defaults" must be indistinguishable from "never touched" (no key left behind).
@MainActor
final class ChatPrefsStoreTests: XCTestCase {

    private func freshStore() -> (ChatPrefsStore, UserDefaults) {
        let suite = "test.quenderin.chatprefs"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ChatPrefsStore(defaults: defaults), defaults)
    }

    func testOverridesRoundTripPartialAndFull() {
        let (store, _) = freshStore()
        XCTAssertNil(store.fontStyle(for: "c1"))
        XCTAssertNil(store.fontSize(for: "c1"))

        store.set(fontStyle: "serif", fontSize: nil, for: "c1")
        XCTAssertEqual(store.fontStyle(for: "c1"), "serif")
        XCTAssertNil(store.fontSize(for: "c1"))   // partial override leaves the other on global

        store.set(fontStyle: "serif", fontSize: "large", for: "c1")
        XCTAssertEqual(store.fontSize(for: "c1"), "large")
    }

    func testAllDefaultsRemovesTheKeyEntirely() {
        let (store, defaults) = freshStore()
        store.set(fontStyle: "monospaced", fontSize: "small", for: "c1")
        store.set(fontStyle: nil, fontSize: nil, for: "c1")
        XCTAssertNil(defaults.dictionary(forKey: "quenderin.chatprefs.c1"),
                     "clearing both overrides must delete the key — 'all defaults' == 'never touched'")
    }

    func testClearDropsOverrides() {
        let (store, _) = freshStore()
        store.set(fontStyle: "serif", fontSize: nil, for: "doomed")
        store.clear(for: "doomed")
        XCTAssertNil(store.fontStyle(for: "doomed"))
    }
}
