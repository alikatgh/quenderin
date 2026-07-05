import XCTest
@testable import QuenderinKit

/// Milestone 1: documents-as-text in chat. Twin of the Kotlin CoreVerify "documents in chat"
/// checks — extraction, engine composition, persistence round-trip + backward compatibility.
final class DocumentAttachmentTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: extraction

    func testExtractorReadsCapsAndRejects() throws {
        let ok = tempDir.appendingPathComponent("notes.txt")
        try "local plans".write(to: ok, atomically: true, encoding: .utf8)
        guard case .document(let doc) = DocumentTextExtractor.extract(name: "notes.txt", url: ok) else {
            return XCTFail("plain text should extract")
        }
        XCTAssertEqual(doc.text, "local plans")

        let big = tempDir.appendingPathComponent("big.txt")
        try String(repeating: "b", count: 4000).write(to: big, atomically: true, encoding: .utf8)
        guard case .document(let bigDoc) = DocumentTextExtractor.extract(name: "big.txt", url: big, maxBytes: 1024) else {
            return XCTFail("oversized text should extract truncated")
        }
        XCTAssertTrue(bigDoc.text.hasSuffix("[…file truncated at 1 KB]"))

        let bin = tempDir.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: bin)
        guard case .rejected(let reason) = DocumentTextExtractor.extract(name: "blob.bin", url: bin) else {
            return XCTFail("binary must be rejected, not mangled")
        }
        XCTAssertTrue(reason.contains("isn't a text file"))
    }

    // MARK: engine composition

    /// Records the exact history the engine was handed, then streams a fixed reply.
    private final class RecordingEngine: InferenceEngine, @unchecked Sendable {
        var lastHistory: [ChatMessage] = []
        func loadedModelID() async -> String? { "recording" }
        func load(model: ModelEntry, at fileURL: URL) async throws {}
        func unload() async {}
        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("ok"); $0.finish() }
        }
        func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            lastHistory = history
            return AsyncThrowingStream { $0.yield("ok"); $0.finish() }
        }
    }

    @MainActor
    func testSendComposesDocumentsForEngineKeepsBubbleClean() async {
        let engine = RecordingEngine()
        let chat = ChatModel(engine: engine)
        let doc = AttachedDocument(name: "plan.txt", text: "ship milestone one")
        await chat.send("what does the plan say?", documents: [doc])

        // The transcript keeps the typed text + chip metadata (bubble stays readable)…
        XCTAssertEqual(chat.messages.first?.text, "what does the plan say?")
        XCTAssertEqual(chat.messages.first?.documents, [doc])
        // …while the ENGINE saw the composed engineText, with the doc clearly labeled.
        let sent = engine.lastHistory.first { $0.role == .user }
        XCTAssertTrue(sent?.text.contains("Attached file \"plan.txt\":\nship milestone one") ?? false)
        XCTAssertTrue(sent?.text.hasSuffix("what does the plan say?") ?? false)
    }

    @MainActor
    func testDocumentsOnlySendIsLegitimate() async {
        let engine = RecordingEngine()
        let chat = ChatModel(engine: engine)
        await chat.send("", documents: [AttachedDocument(name: "a.txt", text: "alpha")])
        XCTAssertEqual(chat.messages.count, 2, "docs-only send must not no-op")
        XCTAssertTrue(engine.lastHistory.first?.text.contains("alpha") ?? false)
    }

    // MARK: persistence

    func testStoreRoundTripsDocumentsAndDecodesOldFormat() throws {
        let store = ConversationStore()
        let messages = [
            ChatMessage(role: .user, text: "see attached", documents: [AttachedDocument(name: "n.txt", text: "line1\nline2\ttabbed")]),
            ChatMessage(role: .assistant, text: "got it"),
        ]
        let decoded = try store.decode(try store.encode(messages))
        XCTAssertEqual(decoded.map(\.text), ["see attached", "got it"])
        XCTAssertEqual(decoded.first?.documents, messages.first?.documents)

        // Pre-Milestone-1 blob (no documents field) still decodes.
        let old = Data(#"[{"role":"user","text":"hi"},{"role":"assistant","text":"hello"}]"#.utf8)
        let oldDecoded = try store.decode(old)
        XCTAssertEqual(oldDecoded.map(\.text), ["hi", "hello"])
        XCTAssertEqual(oldDecoded.first?.documents, [])
    }
}
