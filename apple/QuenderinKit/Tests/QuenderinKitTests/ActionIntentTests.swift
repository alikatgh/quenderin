import XCTest
@testable import QuenderinKit

/// Fixtures kept VERBATIM in the Kotlin twin's CoreVerify check — the two platforms must
/// classify the same messages the same way.
final class ActionIntentTests: XCTestCase {

    func testComputerTasksAreDetected() {
        let tasks = [
            "open browser and write email to i@alink.ru",     // the live report, verbatim
            "Open Safari and search for flights",
            "send an email to my landlord about the lease",
            "compose a message to the team",
            "organize my downloads folder",
            "clean up the files on my desktop",
            "move the PDF files to the archive folder",
            "run my morning shortcut",
            "create a folder called Taxes 2026",
        ]
        for text in tasks {
            XCTAssertTrue(ActionIntent.looksLikeComputerTask(text), "should detect: \(text)")
        }
    }

    func testQuestionsAndChatAreNotDetected() {
        let chat = [
            "what is an email address",
            "how does a browser render HTML",
            "why did my message bounce",
            "explain the difference between a file and a folder",
            "who invented the shortcut for copy and paste",
            "convert 5 miles to km, then take 20% of that",
            "days until 2027-01-01",
        ]
        for text in chat {
            XCTAssertFalse(ActionIntent.looksLikeComputerTask(text), "should NOT detect: \(text)")
        }
    }

    /// The educational short-circuit must teach the path, not refuse at length.
    func testGuidedReplyEducatesWithoutWallOfRefusal() {
        let reply = ActionIntent.guidedAssistantReply
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("Agent"), "must name the Agent")
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("sparkle")
                      || reply.localizedCaseInsensitiveContains("sidebar"),
                      "must point at the rail control")
        XCTAssertFalse(reply.localizedCaseInsensitiveContains("I cannot fulfill"),
                       "no dead-end refusal prose")
        XCTAssertEqual(ActionIntent.handoffButtonTitle, "Open in Agent")
    }

    func testOldAgentRedirectProseIsRewrittenForDisplay() {
        let wall = "I cannot fulfill that request. I am running entirely offline and do not have "
            + "the ability to operate your computer. Please use the Agent tab (the sparkle icon)."
        XCTAssertTrue(ActionIntent.looksLikeAgentRedirectProse(wall))
        XCTAssertEqual(ActionIntent.displayAssistantText(wall), ActionIntent.guidedAssistantReply)
        XCTAssertFalse(ActionIntent.looksLikeAgentRedirectProse("Село Хочо находится в префектуре Нагано."))
        XCTAssertEqual(ActionIntent.displayAssistantText("Paris is the capital."),
                       "Paris is the capital.")
    }
}
