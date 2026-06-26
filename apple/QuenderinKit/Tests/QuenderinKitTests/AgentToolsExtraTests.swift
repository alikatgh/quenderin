import XCTest
@testable import QuenderinKit

final class UnitConverterToolTests: XCTestCase {
    private let tool = UnitConverterTool()

    func testCleanConversions() async throws {
        let cases: [(String, String)] = [
            ("1 km to m", "1 km = 1000 m"),
            ("1000 m to km", "1000 m = 1 km"),
            ("100 cm to m", "100 cm = 1 m"),
            ("2 kg to g", "2 kg = 2000 g"),
            ("2 l to ml", "2 l = 2000 ml"),
            ("30 C to F", "30 c = 86 f"),       // affine temperature
            ("32 F to C", "32 f = 0 c"),
            ("100 cm in m", "100 cm = 1 m"),    // "in" separator
            ("2 hours to minutes", "2 h = 120 min"),   // time (spelled-out aliases)
            ("90 min to h", "90 min = 1.5 h"),
            ("1 day to hours", "1 day = 24 h"),
        ]
        for (input, expected) in cases {
            let result = try await tool.run(input)
            XCTAssertEqual(result, expected, "for \"\(input)\"")
        }
    }

    func testFractionalAndAliasConversions() async throws {
        let mi = try await tool.run("20 km to mi")
        XCTAssertTrue(mi.contains("12.42"), "20 km ≈ 12.4274 mi, got \(mi)")
        let k = try await tool.run("0 C to K")
        XCTAssertTrue(k.contains("273.15"), "0°C = 273.15 K, got \(k)")
        let alias = try await tool.run("5 kilometers to miles")  // spelled-out aliases
        XCTAssertTrue(alias.contains("3.10"), "5 km ≈ 3.1069 mi, got \(alias)")
    }

    func testRejectsCrossDimensionAndGarbage() async throws {
        let cross = try await tool.run("5 kg to mi")            // mass → length
        XCTAssertTrue(cross.contains("Can't convert"), "got \(cross)")
        let tempCross = try await tool.run("30 C to km")        // temp → length
        XCTAssertTrue(tempCross.contains("Can't convert"), "got \(tempCross)")
        for bad in ["hello world", "convert stuff", "delete everything"] {
            let out = try await tool.run(bad)
            XCTAssertTrue(out.contains("Couldn't read"), "expected rejection for \"\(bad)\", got \(out)")
        }
    }
}

final class DateCalcToolTests: XCTestCase {
    private let tool = DateCalcTool()

    func testDaysBetween() async throws {
        let a = try await tool.run("days between 2026-06-08 and 2026-12-25")
        XCTAssertEqual(a, "200 days")
        let one = try await tool.run("days between 2026-01-01 and 2026-01-02")
        XCTAssertEqual(one, "1 day")                              // singular
        let reversed = try await tool.run("days between 2026-12-25 and 2026-06-08")
        XCTAssertEqual(reversed, "200 days")                     // order-independent
    }

    func testAddAndSubtractDays() async throws {
        let plus = try await tool.run("2026-06-08 plus 90 days")
        XCTAssertEqual(plus, "2026-09-06")
        let minus = try await tool.run("2026-12-25 minus 14 days")
        XCTAssertEqual(minus, "2026-12-11")
    }

    func testRejectsGarbage() async throws {
        for bad in ["hello", "what time is it", "2026-06-08 sideways 3 days"] {
            let out = try await tool.run(bad)
            XCTAssertTrue(out.contains("Couldn't read"), "expected rejection for \"\(bad)\", got \(out)")
        }
    }

    /// Calendar-invalid dates must be REJECTED, not silently rolled over. DateFormatter would turn
    /// 2026-02-30 into 2026-03-02 (and a non-leap 2026-02-29 into 2026-03-01) and compute from a date
    /// the user never typed — and disagree with Android's strict java.time.LocalDate. Parity contract.
    func testRejectsCalendarInvalidDates() async throws {
        for bad in ["days between 2026-02-30 and 2026-12-25", "2026-06-31 plus 5 days", "2026-02-29 plus 1 day"] {
            let out = try await tool.run(bad)
            XCTAssertTrue(out.contains("Couldn't read"), "invalid date should be rejected, not rolled over: \"\(bad)\" → \(out)")
        }
        // A real leap day (2024) stays valid on both platforms.
        let leap = try await tool.run("2024-02-29 plus 1 day")
        XCTAssertEqual(leap, "2024-03-01")
    }
}
