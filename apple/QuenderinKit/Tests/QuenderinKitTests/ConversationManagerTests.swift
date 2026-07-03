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

    func testStartNewDefersTheIndexRowUntilFirstSave() {
        let persistence = InMemoryConversationPersistence()
        let (mgr, _) = make(persistence)
        let id = mgr.startNew()
        XCTAssertEqual(mgr.currentID, id)
        XCTAssertTrue(mgr.list().isEmpty, "no history row until something is said (WhatsApp rule)")
        XCTAssertTrue(persistence.loadIndex().isEmpty, "an abandoned new chat writes nothing")
        mgr.save(id: id, messages: [u("hi")])
        XCTAssertEqual(mgr.list().map(\.id), [id])
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
        let first = mgr.startNew()
        mgr.save(id: first, messages: [u("first")]); tick()
        let second = mgr.startNew()
        mgr.save(id: second, messages: [u("second")])
        XCTAssertEqual(mgr.list().map(\.id).first, second, "newest conversation is on top")
        tick()
        mgr.save(id: first, messages: [u("first"), a("reply")])   // touch the older one
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

    func testPruneEmptyConversationsDropsBlankShellsAndKeepsRealOnes() {
        let persistence = InMemoryConversationPersistence()
        // A legacy index as the old create-immediately startNew() wrote it: one real conversation
        // plus abandoned "New conversation" shells (one with an empty transcript, one with none).
        persistence.saveTranscript(id: "real", messages: [u("keep me")])
        persistence.saveTranscript(id: "blank1", messages: [])
        persistence.saveIndex([
            ConversationSummary(id: "real", title: "keep me", updatedAt: 1),
            ConversationSummary(id: "blank1", title: "New conversation", updatedAt: 2),
            ConversationSummary(id: "blank2", title: "New conversation", updatedAt: 3),
        ])
        let mgr = ConversationManager(persistence: persistence, now: { 9 }, makeID: { "x" })
        mgr.pruneEmptyConversations()
        XCTAssertEqual(mgr.list().map(\.id), ["real"])
        XCTAssertEqual(persistence.loadIndex().map(\.id), ["real"])
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
