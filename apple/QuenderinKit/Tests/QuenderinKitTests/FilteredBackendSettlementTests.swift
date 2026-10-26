import XCTest
@testable import QuenderinKit

/// The shipped final-channel filters driven through `ChatModel`: only visible text may settle, at
/// every chunk boundary, and `finish()` never leaks a partial control fragment. Kotlin's
/// `FilteredBackendSettlementTest` pins the same wires; its engine also returns `finalText(wire)`,
/// while Swift's stream is the only engine channel.
@MainActor
final class FilteredBackendSettlementTests: XCTestCase {

    private enum Kind: Sendable { case beam, muse, jais }

    private actor FilteredEngine: InferenceEngine {
        private let kind: Kind
        private let chunks: [String]
        private var loaded: String? = "filtered"

        init(kind: Kind, chunks: [String]) {
            self.kind = kind
            self.chunks = chunks
        }

        func loadedModelID() async -> String? { loaded }
        func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
        func unload() async { loaded = nil }

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            guard loaded != nil else { throw InferenceError.modelNotLoaded }
            let kind = self.kind
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                switch kind {
                case .beam:
                    var filter = BeamFinalChannelFilter()
                    for chunk in chunks {
                        let out = filter.feed(chunk)
                        if !out.isEmpty { continuation.yield(out) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { continuation.yield(tail) }
                case .muse:
                    var filter = MuseFinalChannelFilter()
                    for chunk in chunks {
                        let out = filter.feed(chunk)
                        if !out.isEmpty { continuation.yield(out) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { continuation.yield(tail) }
                case .jais:
                    var filter = JaisFinalChannelFilter()
                    for chunk in chunks {
                        let out = filter.feed(chunk)
                        if !out.isEmpty { continuation.yield(out) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { continuation.yield(tail) }
                }
                continuation.finish()
            }
        }
    }

    private func settle(_ kind: Kind, chunks: [String]) async -> String {
        let engine = FilteredEngine(kind: kind, chunks: chunks)
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        let chat = ChatModel(engine: engine)
        await chat.send("question")
        return chat.messages.last?.text ?? ""
    }

    func testBeamSettlesOnlyTheFinalChannelAcrossChunkBoundaries() async {
        let wire = "<|channel|>analysis<|message|>PRIVATE<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>Hello 🌲<|return|>hidden"
        for split in 0...wire.count {
            let index = wire.index(wire.startIndex, offsetBy: split)
            let text = await settle(.beam, chunks: [String(wire[..<index]), String(wire[index...])])
            XCTAssertEqual(text, "Hello 🌲", "split=\(split)")
        }
    }

    func testMuseSettlesOnlyTheUserChannelAcrossChunkBoundaries() async {
        let wire = " to=self<|message|>secret chain<|eom|><|start|>assistant to=commentary<|message|>aside"
            + "<|eom|><|start|>assistant to=user<|message|>Final answer.<|eot|>trailing hidden"
        for split in 0...wire.count {
            let index = wire.index(wire.startIndex, offsetBy: split)
            let text = await settle(.muse, chunks: [String(wire[..<index]), String(wire[index...])])
            XCTAssertEqual(text, "Final answer.", "split=\(split)")
        }
    }

    func testJaisSettlesOnlyTextAfterPrivateReasoningAcrossChunkBoundaries() async {
        let wire = "private reasoning</ifm|think>مرحباً world<|ifm|im_end|>hidden next turn"
        for split in 0...wire.count {
            let index = wire.index(wire.startIndex, offsetBy: split)
            let text = await settle(.jais, chunks: [String(wire[..<index]), String(wire[index...])])
            XCTAssertEqual(text, "مرحباً world", "split=\(split)")
        }
    }

    func testFinishDropsPartialControlTails() {
        var beam = BeamFinalChannelFilter()
        let beamBody = beam.feed("<|channel|>final<|message|>Hello<|ret")
        let beamText = beamBody + beam.finish()
        XCTAssertEqual(beamText, "Hello")

        var muse = MuseFinalChannelFilter()
        let museBody = muse.feed(" to=user<|message|>Answer<|eo")
        let museText = museBody + muse.finish()
        XCTAssertEqual(museText, "Answer")

        var jais = JaisFinalChannelFilter()
        let jaisBody = jais.feed("private</ifm|think>answer<|ifm|im_")
        let jaisText = jaisBody + jais.finish()
        XCTAssertEqual(jaisText, "answer")
    }

    func testTrailingVisibleTailSettlesWithoutATerminatingControl() async {
        let beam = await settle(.beam, chunks: ["<|channel|>final<|message|>Tail without terminator"])
        XCTAssertEqual(beam, "Tail without terminator")

        let muse = await settle(.muse, chunks: [" to=user<|message|>Tail without terminator"])
        XCTAssertEqual(muse, "Tail without terminator")

        let jais = await settle(.jais, chunks: ["private</ifm|think>Tail without terminator"])
        XCTAssertEqual(jais, "Tail without terminator")
    }

    func testPrivateOnlyWireSettlesToTheHonestNotice() async {
        let text = await settle(.beam, chunks: ["<|channel|>analysis<|message|>only private<|end|>"])
        XCTAssertEqual(text, ChatUserFacing.emptyReply())
    }
}
