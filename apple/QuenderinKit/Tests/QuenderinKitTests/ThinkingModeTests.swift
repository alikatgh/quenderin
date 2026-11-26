import XCTest
@testable import QuenderinKit

final class ThinkingModeTests: XCTestCase {
    func testModeDefaultsRawValuesAndAllowsThinking() {
        XCTAssertEqual(ThinkingMode.defaultMode, .off)
        XCTAssertEqual(ThinkingMode.off.rawValue, "off")
        XCTAssertEqual(ThinkingMode.show.rawValue, "show")
        XCTAssertEqual(ThinkingMode.hide.rawValue, "hide")
        XCTAssertFalse(ThinkingMode.off.allowsThinking)
        XCTAssertTrue(ThinkingMode.show.allowsThinking)
        XCTAssertTrue(ThinkingMode.hide.allowsThinking)
    }

    func testSupportsTemplateDetection() {
        XCTAssertTrue(ThinkingMode.supports(template: "{% if enable_thinking %}<think>{% endif %}"))
        XCTAssertTrue(ThinkingMode.supports(template: "assistant\n<think>\n"))
        XCTAssertTrue(ThinkingMode.supports(template: "some template with enable_thinking flag"))
        XCTAssertFalse(ThinkingMode.supports(template: "<|im_start|>assistant\n"))
        XCTAssertFalse(ThinkingMode.supports(template: ""))
    }

    func testSingleChunkThinkAndAnswer() {
        var splitter = ThinkingSplitter()
        XCTAssertFalse(splitter.isThinking)
        let first = splitter.feed("<think>step 1\nstep 2</think>Final answer.")
        XCTAssertEqual(first.thinking, "step 1\nstep 2")
        XCTAssertEqual(first.answer, "Final answer.")
        XCTAssertFalse(splitter.isThinking)
        let tail = splitter.finish()
        XCTAssertEqual(tail.thinking, "")
        XCTAssertEqual(tail.answer, "")
    }

    func testTagsSplitOneCharAtATime() {
        let stream = "  \n<think>reason one</think>42 is the answer"
        var splitter = ThinkingSplitter()
        var thinking = ""
        var answer = ""
        var sawThinkingState = false
        for ch in stream {
            let delta = splitter.feed(String(ch))
            thinking += delta.thinking
            answer += delta.answer
            if splitter.isThinking { sawThinkingState = true }
        }
        let tail = splitter.finish()
        thinking += tail.thinking
        answer += tail.answer

        XCTAssertTrue(sawThinkingState)
        XCTAssertFalse(splitter.isThinking)
        XCTAssertEqual(thinking, "reason one")
        XCTAssertEqual(answer, "42 is the answer")
    }

    func testStartsInsideThinkingPreOpenedTemplate() {
        var splitter = ThinkingSplitter(startsInsideThinking: true)
        XCTAssertTrue(splitter.isThinking)
        let a = splitter.feed("checking math </thi")
        XCTAssertEqual(a.thinking, "checking math ")
        XCTAssertEqual(a.answer, "")
        XCTAssertTrue(splitter.isThinking)

        let b = splitter.feed("nk>The result is 4.")
        XCTAssertEqual(b.thinking, "")
        XCTAssertEqual(b.answer, "The result is 4.")
        XCTAssertFalse(splitter.isThinking)

        let tail = splitter.finish()
        XCTAssertEqual(tail.thinking, "")
        XCTAssertEqual(tail.answer, "")
    }

    func testNoThinkTagsAtAllPassesEverythingToAnswer() {
        var splitter = ThinkingSplitter()
        let a = splitter.feed("Hello ")
        let b = splitter.feed("world!")
        let tail = splitter.finish()
        XCTAssertEqual(a.thinking + b.thinking + tail.thinking, "")
        XCTAssertEqual(a.answer + b.answer + tail.answer, "Hello world!")
        XCTAssertFalse(splitter.isThinking)
    }

    func testLeadingWhitespaceDroppedBeforeThinkAndPreservedWithoutThink() {
        var withThink = ThinkingSplitter()
        let r1 = withThink.feed(" \t\r\n ")
        XCTAssertEqual(r1.thinking, "")
        XCTAssertEqual(r1.answer, "")
        let r2 = withThink.feed("<think>ok</think>yes")
        let r3 = withThink.finish()
        XCTAssertEqual(r2.thinking + r3.thinking, "ok")
        XCTAssertEqual(r2.answer + r3.answer, "yes")

        var withoutThink = ThinkingSplitter()
        let n1 = withoutThink.feed("   ")
        XCTAssertEqual(n1.answer, "")
        let n2 = withoutThink.feed("plain reply")
        let n3 = withoutThink.finish()
        XCTAssertEqual(n1.thinking + n2.thinking + n3.thinking, "")
        XCTAssertEqual(n1.answer + n2.answer + n3.answer, "   plain reply")

        // Split CRLF across separate chunks before `<think>` and before plain text.
        var splitCrlfThink = ThinkingSplitter()
        XCTAssertEqual(splitCrlfThink.feed("\r").answer, "")
        XCTAssertEqual(splitCrlfThink.feed("\n").answer, "")
        let sc1 = splitCrlfThink.feed("<think>split</think>ok")
        let sc2 = splitCrlfThink.finish()
        XCTAssertEqual(sc1.thinking + sc2.thinking, "split")
        XCTAssertEqual(sc1.answer + sc2.answer, "ok")

        var splitCrlfPlain = ThinkingSplitter()
        XCTAssertEqual(splitCrlfPlain.feed("\r").answer, "")
        XCTAssertEqual(splitCrlfPlain.feed("\n").answer, "")
        let sp1 = splitCrlfPlain.feed("hello")
        let sp2 = splitCrlfPlain.finish()
        XCTAssertEqual(sp1.thinking + sp2.thinking, "")
        XCTAssertEqual(sp1.answer + sp2.answer, "\r\nhello")
    }

    func testUnclosedThinkingAtFinishGoesEntirelyToThinking() {
        var splitter = ThinkingSplitter()
        let a = splitter.feed("<think>still thinking</thi")
        XCTAssertTrue(splitter.isThinking)
        let tail = splitter.finish()
        XCTAssertFalse(splitter.isThinking)
        XCTAssertEqual(a.thinking + tail.thinking, "still thinking</thi")
        XCTAssertEqual(a.answer + tail.answer, "")
    }

    func testUnclosedPreOpenedThinkingAtFinish() {
        var splitter = ThinkingSplitter(startsInsideThinking: true)
        let a = splitter.feed("deep thought")
        let tail = splitter.finish()
        XCTAssertEqual(a.thinking + tail.thinking, "deep thought")
        XCTAssertEqual(a.answer + tail.answer, "")
    }

    func testFalseAlarmPartialTagsInsideAndOutsideThinking() {
        var s1 = ThinkingSplitter()
        let o1 = s1.feed(" <thi")
        XCTAssertEqual(o1.answer, "")
        let o2 = s1.feed("s> is text")
        let o3 = s1.finish()
        XCTAssertEqual(o1.thinking + o2.thinking + o3.thinking, "")
        XCTAssertEqual(o1.answer + o2.answer + o3.answer, " <this> is text")

        var s2 = ThinkingSplitter()
        let t1 = s2.feed("<think>a </thi")
        let t2 = s2.feed("s> b</think>done")
        let t3 = s2.finish()
        XCTAssertEqual(t1.thinking + t2.thinking + t3.thinking, "a </this> b")
        XCTAssertEqual(t1.answer + t2.answer + t3.answer, "done")
    }

    func testEmptyThinkBlockAndMultiChunkAnswer() {
        var splitter = ThinkingSplitter()
        let p1 = splitter.feed("<think></think>")
        XCTAssertEqual(p1.thinking, "")
        XCTAssertEqual(p1.answer, "")
        XCTAssertFalse(splitter.isThinking)
        let p2 = splitter.feed("first ")
        let p3 = splitter.feed("second")
        let tail = splitter.finish()
        XCTAssertEqual(p2.answer + p3.answer + tail.answer, "first second")
        XCTAssertEqual(p2.thinking + p3.thinking + tail.thinking, "")
    }

    func testWhitespaceOnlyOrIncompleteOpenAtFinishGoesToAnswer() {
        var wsOnly = ThinkingSplitter()
        _ = wsOnly.feed("   ")
        let wsTail = wsOnly.finish()
        XCTAssertEqual(wsTail.thinking, "")
        XCTAssertEqual(wsTail.answer, "   ")

        var partialOpen = ThinkingSplitter()
        _ = partialOpen.feed("<thi")
        let poTail = partialOpen.finish()
        XCTAssertEqual(poTail.thinking, "")
        XCTAssertEqual(poTail.answer, "<thi")
    }
}
