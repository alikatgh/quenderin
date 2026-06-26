import XCTest
@testable import QuenderinKit

final class AgentToolTests: XCTestCase {

    func testEchoReturnsInput() async throws {
        let output = try await EchoTool().run("hello")
        XCTAssertEqual(output, "hello")
    }

    func testCalculatorBasicArithmetic() async throws {
        let calc = CalculatorTool()
        let cases: [(input: String, expected: String)] = [
            ("2 + 2", "4"),
            ("12 * (3 + 4)", "84"),
            ("10 / 4", "2.5"),
            ("-3 + 5", "2"),
            ("2 * -3", "-6"),
        ]
        for (input, expected) in cases {
            let result = try await calc.run(input)
            XCTAssertEqual(result, expected, "for \(input)")
        }
    }

    func testCalculatorExponentiation() async throws {
        let calc = CalculatorTool()
        // ^ is right-associative, binds tighter than * /, and unary minus is looser than ^.
        let cases: [(input: String, expected: String)] = [
            ("2^10", "1024"),
            ("2^3^2", "512"),     // 2^(3^2) = 2^9, NOT (2^3)^2 = 64
            ("2*3^2", "18"),      // ^ before *
            ("-2^2", "-4"),       // -(2^2)
            ("(-2)^2", "4"),
            ("2^-1", "0.5"),      // negative exponent
        ]
        for (input, expected) in cases {
            let result = try await calc.run(input)
            XCTAssertEqual(result, expected, "for \(input)")
        }
        // Non-finite results (NaN / Inf) must be rejected, not rendered as "nan"/"inf".
        for bad in ["(-2)^0.5", "2^9999"] {
            let out = try await calc.run(bad)
            XCTAssertTrue(out.contains("Couldn't evaluate"), "for \(bad)")
        }
    }

    func testCalculatorModulo() async throws {
        let calc = CalculatorTool()
        let cases: [(input: String, expected: String)] = [
            ("10 % 3", "1"),
            ("2 * 3 % 4", "2"),    // (2*3)%4 = 6%4 = 2 (left-assoc, same level as *)
            ("-10 % 3", "-1"),
        ]
        for (input, expected) in cases {
            let result = try await calc.run(input)
            XCTAssertEqual(result, expected, "for \(input)")
        }
        let byZero = try await calc.run("10 % 0")
        XCTAssertTrue(byZero.contains("Couldn't evaluate"), "modulo by zero must be rejected")
    }

    func testCalculatorFunctionsAndConstants() async throws {
        let calc = CalculatorTool()
        let cases: [(input: String, expected: String)] = [
            ("sqrt(16)", "4"),
            ("sqrt(9)", "3"),
            ("abs(-7)", "7"),
            ("floor(2.7)", "2"),
            ("ceil(2.1)", "3"),
            ("floor(pi)", "3"),       // constant pi + floor
            ("floor(e)", "2"),        // constant e + floor
            ("2 * sqrt(9)", "6"),     // function inside an expression
            ("sqrt(9) ^ 2", "9"),     // function then power
        ]
        for (input, expected) in cases {
            let result = try await calc.run(input)
            XCTAssertEqual(result, expected, "for \(input)")
        }
        // sqrt of a negative is NaN → rejected; unsupported names (incl. log, which we DON'T add) → rejected.
        for bad in ["sqrt(-1)", "foo(2)", "log(10)"] {
            let out = try await calc.run(bad)
            XCTAssertTrue(out.contains("Couldn't evaluate"), "for \(bad)")
        }
    }

    func testCalculatorRejectsGarbageWithoutCrashing() async throws {
        let calc = CalculatorTool()
        for bad in ["2 +* 2", "delete everything", "1 / 0", "()", "((1)"] {
            let output = try await calc.run(bad)
            XCTAssertTrue(output.contains("Couldn't evaluate"), "expected rejection for \"\(bad)\", got \(output)")
        }
    }
}
