import XCTest
@testable import QuenderinKit

final class ChatUserFacingTests: XCTestCase {
    func testEmptyReplyEnglishDefault() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ChatUserFacing.emptyReply(locale: en), ChatUserFacing.emptyReplyEnglish)
        XCTAssertTrue(ChatUserFacing.emptyReply(locale: en).contains("empty reply"))
    }

    func testEmptyReplyRussian() {
        let ru = Locale(identifier: "ru_RU")
        let text = ChatUserFacing.emptyReply(locale: ru)
        XCTAssertTrue(text.contains("пустой"), text)
        XCTAssertNotEqual(text, ChatUserFacing.emptyReplyEnglish)
    }

    func testContinueCueLocalePacks() {
        XCTAssertEqual(
            ChatUserFacing.continueCue(locale: Locale(identifier: "en_US")),
            ChatUserFacing.continueCueEnglish
        )
        let ru = ChatUserFacing.continueCue(locale: Locale(identifier: "ru_RU"))
        XCTAssertTrue(ru.contains("Продолжи"), ru)
        let de = ChatUserFacing.continueCue(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(de, ChatUserFacing.continueCueEnglish, "unknown locale falls back to English")
    }
}
