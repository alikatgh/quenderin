import XCTest
import Foundation
@testable import QuenderinKit

/// Thermal-adaptive threading: as the phone heats up, inference sheds threads so a long
/// generation stays sustainable instead of throttling to a crawl or getting the app killed.
final class ThermalThrottleTests: XCTestCase {

    func testThreadsDropAsDeviceHeatsUp() {
        // Monotonic non-increasing: hotter → never more threads.
        XCTAssertEqual(ThermalThrottle.recommendedThreads(level: .nominal, baseThreads: 4), 4)
        XCTAssertEqual(ThermalThrottle.recommendedThreads(level: .fair, baseThreads: 4), 3)
        XCTAssertEqual(ThermalThrottle.recommendedThreads(level: .serious, baseThreads: 4), 2)
        XCTAssertEqual(ThermalThrottle.recommendedThreads(level: .critical, baseThreads: 4), 1)
    }

    func testNeverDropsBelowOneThread() {
        for level in [ThermalLevel.nominal, .fair, .serious, .critical] {
            XCTAssertGreaterThanOrEqual(
                ThermalThrottle.recommendedThreads(level: level, baseThreads: 1), 1,
                "\(level) must keep at least one thread")
        }
        // A degenerate base still yields a runnable thread count.
        XCTAssertEqual(ThermalThrottle.recommendedThreads(level: .nominal, baseThreads: 0), 1)
    }

    func testMonotonicAcrossBaseCounts() {
        for base in [2, 6, 8] {
            let n = ThermalThrottle.recommendedThreads(level: .nominal, baseThreads: base)
            let f = ThermalThrottle.recommendedThreads(level: .fair, baseThreads: base)
            let s = ThermalThrottle.recommendedThreads(level: .serious, baseThreads: base)
            let c = ThermalThrottle.recommendedThreads(level: .critical, baseThreads: base)
            XCTAssertGreaterThanOrEqual(n, f)
            XCTAssertGreaterThanOrEqual(f, s)
            XCTAssertGreaterThanOrEqual(s, c)
        }
    }

    /// The OS thermal state → our level mapping (the part we can test without a hot device).
    func testProcessInfoStateMapping() {
        XCTAssertEqual(ThermalMonitor.level(from: .nominal), .nominal)
        XCTAssertEqual(ThermalMonitor.level(from: .fair), .fair)
        XCTAssertEqual(ThermalMonitor.level(from: .serious), .serious)
        XCTAssertEqual(ThermalMonitor.level(from: .critical), .critical)
    }

    /// The live read returns a valid level on whatever machine runs the tests.
    func testCurrentLevelIsValid() {
        let level = ThermalMonitor.currentLevel()
        XCTAssertTrue([.nominal, .fair, .serious, .critical].contains(level))
    }
}
