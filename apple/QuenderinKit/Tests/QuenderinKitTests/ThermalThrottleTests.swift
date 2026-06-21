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

    // MARK: - In-flight governor (re-tuning threads during generation)

    func testGovernorNoChangeWhenLevelStable() {
        var g = ThermalGovernor(baseThreads: 4, initialLevel: .nominal)
        XCTAssertEqual(g.currentThreads, 4)
        XCTAssertNil(g.update(level: .nominal), "same level → no re-tune")
        XCTAssertNil(g.update(level: .nominal))
    }

    func testGovernorShedsThenRecoversThreads() {
        var g = ThermalGovernor(baseThreads: 4, initialLevel: .nominal)
        XCTAssertEqual(g.update(level: .serious), 2, "heating up halves the threads")
        XCTAssertEqual(g.currentThreads, 2)
        XCTAssertEqual(g.update(level: .critical), 1, "critical → single core")
        XCTAssertEqual(g.update(level: .nominal), 4, "cooling back down restores the full count")
    }

    /// Two distinct levels that map to the SAME thread count must not emit a redundant re-tune
    /// (avoids thrashing llama_set_n_threads at a boundary).
    func testGovernorSuppressesRedundantRetune() {
        var g = ThermalGovernor(baseThreads: 2, initialLevel: .nominal)  // base 2
        // fair → max(1, 2-1)=1; serious → max(1, 2/2)=1 — same count, different level.
        XCTAssertEqual(g.update(level: .fair), 1)
        XCTAssertNil(g.update(level: .serious), "level changed but thread count is identical → no-op")
    }

    func testGovernorClampsDegenerateBase() {
        var g = ThermalGovernor(baseThreads: 0, initialLevel: .nominal)
        XCTAssertEqual(g.currentThreads, 1)
        XCTAssertNil(g.update(level: .critical), "already at 1 thread → nothing to shed")
    }
}
