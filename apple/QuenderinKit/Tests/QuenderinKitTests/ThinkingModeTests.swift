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

    func testShouldCloseThinkBlockDecision() {
        let qwenTmpl = "{% if enable_thinking %}<think>{% endif %}"
        let r1Tmpl = "assistant\n<think>\n"
        let plainTmpl = "<|im_start|>assistant\n"

        XCTAssertTrue(ThinkingMode.shouldCloseThinkBlock(mode: .off, template: qwenTmpl))
        XCTAssertTrue(ThinkingMode.shouldCloseThinkBlock(mode: .off, template: r1Tmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .show, template: qwenTmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .hide, template: qwenTmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .show, template: r1Tmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .hide, template: r1Tmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .off, template: plainTmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .show, template: plainTmpl))
        XCTAssertFalse(ThinkingMode.shouldCloseThinkBlock(mode: .hide, template: ""))
    }

    func testGenerationOptionsThinkingModeDefaultAndConversationStoreRoundTrip() throws {
        let defaults = GenerationOptions()
        XCTAssertEqual(defaults.thinkingMode, .off)
        let custom = GenerationOptions(maxTokens: 128, thinkingMode: .show)
        XCTAssertEqual(custom.thinkingMode, .show)
        XCTAssertEqual(custom.maxTokens, 128)

        let store = ConversationStore()
        // Old saved JSON without `thinking` decodes cleanly via decodeIfPresent.
        let legacyJSON = Data(#"[{"role":"user","text":"hi"},{"role":"assistant","text":"hello"}]"#.utf8)
        let legacy = try store.decode(legacyJSON)
        XCTAssertEqual(legacy.count, 2)
        XCTAssertNil(legacy[1].thinking)

        // Reviewed thinking round-trips and stays out of the export.
        var reviewed = ChatMessage(role: .assistant, text: "4", thinking: "adding two and two")
        reviewed.thinkingReviewed = true
        let withThinking = [
            ChatMessage(role: .user, text: "2+2?"),
            reviewed,
        ]
        let roundTripped = try store.decode(try store.encode(withThinking))
        XCTAssertEqual(roundTripped.count, 2)
        XCTAssertEqual(roundTripped[1].text, "4")
        XCTAssertEqual(roundTripped[1].thinking, "adding two and two")
        let exported = ConversationExporter.markdown(roundTripped)
        XCTAssertTrue(exported.contains("4"))
        XCTAssertFalse(exported.contains("adding two and two"))
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

    func testPreambleAndMultipleThinkBlocksAcrossAnySplit() {
        // Single-chunk preamble + think + answer.
        var single = ThinkingSplitter()
        let s1 = single.feed("Intro <think>reason</think>Done")
        let s2 = single.finish()
        XCTAssertEqual(s1.thinking + s2.thinking, "reason")
        XCTAssertEqual(s1.answer + s2.answer, "Intro Done")
        XCTAssertFalse(single.isThinking)

        // Multiple blocks + preamble streamed one scalar at a time and at every 2-chunk split point.
        let full = "  Intro <think>r1</think> mid <think>r2</think>Done"
        var byChar = ThinkingSplitter()
        var ct = ""
        var ca = ""
        for scalar in full.unicodeScalars {
            let d = byChar.feed(String(scalar))
            ct += d.thinking
            ca += d.answer
        }
        let ctTail = byChar.finish()
        ct += ctTail.thinking
        ca += ctTail.answer
        XCTAssertEqual(ct, "r1r2")
        XCTAssertEqual(ca, "  Intro  mid Done")

        let scalars = Array(full.unicodeScalars)
        for split in 0...scalars.count {
            var sp = ThinkingSplitter()
            let p1 = String(String.UnicodeScalarView(scalars[..<split]))
            let p2 = String(String.UnicodeScalarView(scalars[split...]))
            let d1 = sp.feed(p1)
            let d2 = sp.feed(p2)
            let d3 = sp.finish()
            XCTAssertEqual(d1.thinking + d2.thinking + d3.thinking, "r1r2", "split=\(split)")
            XCTAssertEqual(d1.answer + d2.answer + d3.answer, "  Intro  mid Done", "split=\(split)")
        }

        // Unclosed second block flushes to thinking; startsInsideThinking followed by a second block.
        var unclosedSecond = ThinkingSplitter()
        let u1 = unclosedSecond.feed("Intro <think>r1</think>mid<think>unclosed</thi")
        XCTAssertTrue(unclosedSecond.isThinking)
        let u2 = unclosedSecond.finish()
        XCTAssertFalse(unclosedSecond.isThinking)
        XCTAssertEqual(u1.thinking + u2.thinking, "r1unclosed</thi")
        XCTAssertEqual(u1.answer + u2.answer, "Intro mid")

        var preOpenedMulti = ThinkingSplitter(startsInsideThinking: true)
        let m1 = preOpenedMulti.feed("first</think>mid<think>second</think>end")
        let m2 = preOpenedMulti.finish()
        XCTAssertEqual(m1.thinking + m2.thinking, "firstsecond")
        XCTAssertEqual(m1.answer + m2.answer, "midend")

        // Trailing partial open tag after preamble flushes to answer on finish.
        var trailingPartial = ThinkingSplitter()
        let tp1 = trailingPartial.feed("Intro <thi")
        XCTAssertEqual(tp1.answer, "Intro ")
        let tp2 = trailingPartial.finish()
        XCTAssertEqual(tp1.thinking + tp2.thinking, "")
        XCTAssertEqual(tp1.answer + tp2.answer, "Intro <thi")
    }

    func testCombiningMarkAfterTagsIsChunkBoundaryIndependent() {
        let oneChunkText = "<think>\u{0301}x</think>A"
        var whole = ThinkingSplitter()
        let w1 = whole.feed(oneChunkText)
        let w2 = whole.finish()
        XCTAssertEqual(w1.thinking + w2.thinking, "\u{0301}x")
        XCTAssertEqual(w1.answer + w2.answer, "A")

        var split = ThinkingSplitter()
        let a = split.feed("<think>")
        let b = split.feed("\u{0301}x</think>A")
        let c = split.finish()
        XCTAssertEqual(a.thinking + b.thinking + c.thinking, "\u{0301}x")
        XCTAssertEqual(a.answer + b.answer + c.answer, "A")

        // Also combining mark immediately after closing tag.
        let closeWholeText = "<think>a</think>\u{0301}B"
        var cw = ThinkingSplitter()
        let cw1 = cw.feed(closeWholeText)
        let cw2 = cw.finish()
        var cs = ThinkingSplitter()
        let cs1 = cs.feed("<think>a</think>")
        let cs2 = cs.feed("\u{0301}B")
        let cs3 = cs.finish()
        XCTAssertEqual(cw1.thinking + cw2.thinking, "a")
        XCTAssertEqual(cw1.answer + cw2.answer, "\u{0301}B")
        XCTAssertEqual(cs1.thinking + cs2.thinking + cs3.thinking, "a")
        XCTAssertEqual(cs1.answer + cs2.answer + cs3.answer, "\u{0301}B")
    }

    func testPromptEndsInsideThinkingAndRenderedPromptSplitter() {
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("<|im_start|>assistant\n<think>\n"))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("<｜Assistant｜><think>"))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("assistant:<think>  \r\n\t"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("User: explain <think>\nAssistant:\n"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(""))

        // Pre-opened prompt: Hide/Show consumers initialize from rendered prompt so reasoning
        // before `</think>` never leaks into the visible answer / API content.
        var preOpened = ThinkingSplitter(renderedPrompt: "<|im_start|>assistant\n<think>\n")
        XCTAssertTrue(preOpened.isThinking)
        let d1 = preOpened.feed("secret reasoning </thi")
        let d2 = preOpened.feed("nk>Visible answer")
        let d3 = preOpened.finish()
        XCTAssertEqual(d1.thinking + d2.thinking + d3.thinking, "secret reasoning ")
        XCTAssertEqual(d1.answer + d2.answer + d3.answer, "Visible answer")

        // Closed prompt: starts outside thinking.
        var closed = ThinkingSplitter(renderedPrompt: "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        XCTAssertFalse(closed.isThinking)
        let c1 = closed.feed("Direct reply")
        let c2 = closed.finish()
        XCTAssertEqual(c1.thinking + c2.thinking, "")
        XCTAssertEqual(c1.answer + c2.answer, "Direct reply")
    }

    func testPreOpenedNonEmptyAssistantPrefixAndUserTagIsolation() {
        // Non-empty pre-opened assistant prefixes must be detected as inside thinking.
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("<|im_start|>assistant\n<think>\nReasoning: "))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("<｜Assistant｜><think>\nStep 1: "))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("<start_of_turn>model\n<think>\nNotes: "))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("User: explain <think>\nAssistant: <think>\nReasoning: "))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("<|im_start|>assistant\n<think>\u{0301}step"))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking("  <think>\nReasoning: "))

        // Closed assistant prefixes with text after </think> must NOT be treated as open.
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<|im_start|>assistant\n<think>\nReasoning: </think>\nAnswer: "))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<think>done</think>"))

        // Literal <think> tags in earlier user messages (including spoofed template markers) must be ignored.
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<|im_start|>user\nexplain <think><|im_end|>\n<|im_start|>assistant\n"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<|start_header_id|>user<|end_header_id|>\n\nWhat is <think>?<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<start_of_turn>user\nexplain <think><end_of_turn>\n<start_of_turn>model\n"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("[INST] explain <think> [/INST]"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<｜User｜>explain <think><｜Assistant｜>"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("<|im_start|>user\nShow <|im_start|>assistant\n<think> example<|im_end|>\n<|im_start|>assistant\n"))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking("User: explain <think>"))

        // 2-argument exact assistant-prefix diff works even for arbitrary custom templates and spoofed user text.
        let customBase = "USER: explain <think> and BOT: <think>\n"
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(customBase + "BOT: ", withoutAssistantPrefix: customBase))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking(customBase + "BOT: <think>\nReasoning: ", withoutAssistantPrefix: customBase))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(customBase + "BOT: <think>\n\n</think>\n\n", withoutAssistantPrefix: customBase))

        // Hide/Show splitter initialized from a non-empty pre-opened assistant prefix never leaks reasoning.
        var splitter = ThinkingSplitter(renderedPrompt: "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\nReasoning: ")
        XCTAssertTrue(splitter.isThinking)
        let a = splitter.feed("private thoughts</think>Visible answer")
        let b = splitter.finish()
        XCTAssertEqual(a.thinking + b.thinking, "private thoughts")
        XCTAssertEqual(a.answer + b.answer, "Visible answer")
    }

    func testPromptEndsInsideThinkingEqualTemplateRenders() {
        // When `add_ass = false` and `add_ass = true` render the exact same prompt (unconditional
        // assistant prefill), 2-argument detection must fall back to turn-boundary inspection
        // rather than subtracting an empty suffix and returning false.
        let equalChatML = "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>"
        let equalChatMLText = "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\nReasoning: "
        let equalDeepSeek = "<｜User｜>hi<｜Assistant｜><think>"
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking(equalChatML, withoutAssistantPrefix: equalChatML))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking(equalChatMLText, withoutAssistantPrefix: equalChatMLText))
        XCTAssertTrue(ThinkingMode.promptEndsInsideThinking(equalDeepSeek, withoutAssistantPrefix: equalDeepSeek))

        // Off-mode close appends only the close tag (not a duplicate <think>), after which the
        // prompt is no longer inside thinking.
        let closedOff = equalChatML + "\n</think>\n\n"
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(closedOff, withoutAssistantPrefix: equalChatML))

        // Equal renders that already closed </think> or contain <think> only in user text remain false.
        let equalClosed = "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let equalUserOnly = "<|im_start|>user\nexplain <think><|im_end|>\n"
        let equalFlatUser = "User: explain <think>"
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(equalClosed, withoutAssistantPrefix: equalClosed))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(equalUserOnly, withoutAssistantPrefix: equalUserOnly))
        XCTAssertFalse(ThinkingMode.promptEndsInsideThinking(equalFlatUser, withoutAssistantPrefix: equalFlatUser))
    }
}
