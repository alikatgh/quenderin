import XCTest
@testable import QuenderinKit

final class DownloadWaitPlaygroundTests: XCTestCase {
    func testChatStartersPack() {
        XCTAssertEqual(ChatStarters.offlineChat.count, 8)
        XCTAssertEqual(Set(ChatStarters.offlineChat.map(\.id)).count, 8, "starter ids must be unique")
        for s in ChatStarters.offlineChat {
            XCTAssertFalse(s.title.isEmpty)
            XCTAssertFalse(s.prompt.isEmpty)
        }
    }

    func testDownloadETANeedsSamples() {
        XCTAssertNil(DownloadETA.estimate(samples: [], progress: 0.5))
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let samples = [
            (t0, 0.10),
            (t0.addingTimeInterval(10), 0.30),
        ]
        let label = DownloadETA.estimate(samples: samples, progress: 0.30, now: t0.addingTimeInterval(10))
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("left"), label ?? "nil")
    }

    func testTipsNonEmptyAndRotate() {
        XCTAssertGreaterThanOrEqual(DownloadWaitTips.all.count, 4)
        let a = DownloadWaitTips.tip(at: Date(timeIntervalSinceReferenceDate: 0), rotateEverySeconds: 6)
        let b = DownloadWaitTips.tip(at: Date(timeIntervalSinceReferenceDate: 12), rotateEverySeconds: 6)
        // Different buckets → different tips (unless count divides evenly in a way that collides).
        XCTAssertFalse(a.isEmpty)
        XCTAssertFalse(b.isEmpty)
        XCTAssertNotEqual(a, b)
    }

    func testTokenCatchScoreAndHighScore() {
        var game = TokenCatchGame()
        // Spawn a few frames so a token appears near top.
        for _ in 0..<30 { game.tick(dt: 0.05) }
        XCTAssertFalse(game.tokens.isEmpty, "expected tokens after ticks")
        let t = game.tokens[0]
        XCTAssertTrue(game.tap(at: t.x, ny: t.y))
        XCTAssertEqual(game.score, 1)
        XCTAssertEqual(game.highScore, 1)
        XCTAssertEqual(game.caught, 1)
        // Miss far away
        XCTAssertFalse(game.tap(at: 0, ny: 0, radius: 0.01))
        XCTAssertEqual(game.score, 1)
    }

    func testTokensFallAndCull() {
        var game = TokenCatchGame()
        // spawnRate ≈ 1.35/s → need ~0.8s for the first token
        for _ in 0..<20 { game.tick(dt: 0.05) }
        guard let first = game.tokens.first else {
            return XCTFail("no token")
        }
        let y0 = first.y
        let id = first.id
        game.tick(dt: 0.2)
        if let still = game.tokens.first(where: { $0.id == id }) {
            XCTAssertGreaterThan(still.y, y0)
        }
        // Long fall should cull everything past the bottom
        for _ in 0..<80 { game.tick(dt: 0.1) }
        XCTAssertTrue(game.tokens.allSatisfy { $0.y <= 1.12 })
    }
}
