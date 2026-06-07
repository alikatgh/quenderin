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

    func testCalculatorRejectsGarbageWithoutCrashing() async throws {
        let calc = CalculatorTool()
        for bad in ["2 +* 2", "delete everything", "1 / 0", "()", "((1)"] {
            let output = try await calc.run(bad)
            XCTAssertTrue(output.contains("Couldn't evaluate"), "expected rejection for \"\(bad)\", got \(output)")
        }
    }
}
