import XCTest
@testable import QuenderinKit

final class ConversationManagerTests: XCTestCase {
    private func u(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    private func a(_ t: String) -> ChatMessage { ChatMessage(role: .assistant, text: t) }

    /// Manager with a controllable clock; the returned `tick` advances time deterministically.
    private func make(_ persistence: ConversationPersistence) -> (ConversationManager, () -> Void) {
        var clock: Int64 = 1000
        let mgr = ConversationManager(persistence: persistence, now: { clock }, makeID: { "id-\(clock)" })
        return (mgr, { clock += 1000 })
    }

    func testStartNewCreatesTitledCurrentListedConversation() {
        let (mgr, _) = make(InMemoryConversationPersistence())
        let id = mgr.startNew()
        XCTAssertEqual(mgr.currentID, id)
        XCTAssertEqual(mgr.list().count, 1)
        XCTAssertEqual(mgr.list().first?.title, "New conversation")
    }

    func testSaveDerivesTitleAndPersistsTranscript() {
        let (mgr, _) = make(InMemoryConversationPersistence())
        let id = mgr.startNew()
        mgr.save(id: id, messages: [u("How do I center a div?"), a("Use flexbox.")])
        XCTAssertEqual(mgr.list().first?.title, "How do I center a div?")
        XCTAssertEqual(mgr.open(id).count, 2)
    }

    func testListIsRecencyOrderedAndATouchReSortsToTop() {
        let (mgr, tick) = make(InMemoryConversationPersistence())
        let first = mgr.startNew(); tick()
        let second = mgr.startNew()
        XCTAssertEqual(mgr.list().map(\.id).first, second, "newest conversation is on top")
        tick()
        mgr.save(id: first, messages: [u("hi")])   // touch the older one
        XCTAssertEqual(mgr.list().map(\.id).first, first, "a touched conversation jumps to the top")
    }

    func testDeleteRemovesEverywhereAndClearsCurrent() {
        let (mgr, _) = make(InMemoryConversationPersistence())
        let id = mgr.startNew()
        mgr.save(id: id, messages: [u("hi")])
        mgr.delete(id)
        XCTAssertTrue(mgr.list().isEmpty)
        XCTAssertNil(mgr.currentID)
        XCTAssertTrue(mgr.open(id).isEmpty)
    }

    func testHistorySurvivesAcrossManagerInstances() {
        let persistence = InMemoryConversationPersistence()
        let (mgr, _) = make(persistence)
        let id = mgr.startNew()
        mgr.save(id: id, messages: [u("remembered question")])
        // A brand-new manager over the same persistence restores the history + transcripts.
        let reopened = ConversationManager(persistence: persistence, now: { 9999 }, makeID: { "x" })
        XCTAssertEqual(reopened.list().map(\.id), [id])
        XCTAssertEqual(reopened.list().first?.title, "remembered question")
        XCTAssertEqual(reopened.open(id).count, 1)
    }
}
