import Foundation

/// A capability the agent can invoke during its loop. On-device and offline —
/// math, text utilities, local search, etc.
///
/// > Deliberately NOT "drive another app": iOS sandboxes one app from
/// > controlling another, so the agent acts through *tools* it owns, not by
/// > pixel-driving the OS. That's the honest, shippable shape of "autonomous"
/// > on iOS.
public protocol AgentTool: Sendable {
    /// Stable identifier the planner emits, e.g. "calculator".
    var name: String { get }
    /// One line the planner sees to decide when to use it.
    var purpose: String { get }
    /// Run with a string input, returning an observation string.
    func run(_ input: String) async throws -> String
}

/// Returns its input verbatim — a deterministic tool for tests and as the
/// simplest possible example.
public struct EchoTool: AgentTool {
    public init() {}
    public let name = "echo"
    public let purpose = "Repeat the input back. Use to restate something."
    public func run(_ input: String) async throws -> String { input }
}

/// Evaluates a simple arithmetic expression (`+ - * /`, parentheses, unary
/// minus, decimals). Uses a hand-rolled recursive-descent parser — NOT
/// NSExpression, which raises uncatchable ObjC exceptions on malformed input.
public struct CalculatorTool: AgentTool {
    public init() {}
    public let name = "calculator"
    public let purpose = "Evaluate arithmetic like \"12 * (3 + 4)\"."

    public func run(_ input: String) async throws -> String {
        guard let value = ArithmeticParser.evaluate(input) else {
            return "Couldn't evaluate \"\(input)\"."
        }
        // Render integers without a trailing .0
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

/// A tiny, safe arithmetic evaluator. Returns nil on any malformed input rather
/// than crashing — important because the input comes from an LLM.
enum ArithmeticParser {
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(tokens: tokenize(text))
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var number = ""
        for char in text where !char.isWhitespace {
            if char.isNumber || char == "." {
                number.append(char)
            } else {
                if !number.isEmpty { tokens.append(number); number = "" }
                if "+-*/()".contains(char) { tokens.append(String(char)) } else { return [] }
            }
        }
        if !number.isEmpty { tokens.append(number) }
        return tokens
    }

    private struct Parser {
        let tokens: [String]
        var pos = 0
        var isAtEnd: Bool { pos >= tokens.count }
        private func peek() -> String? { pos < tokens.count ? tokens[pos] : nil }
        private mutating func advance() -> String? { defer { pos += 1 }; return peek() }

        // expression = term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                _ = advance()
                guard let rhs = parseTerm() else { return nil }
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        // term = factor (('*' | '/') factor)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                _ = advance()
                guard let rhs = parseFactor() else { return nil }
                if op == "/" { guard rhs != 0 else { return nil }; value /= rhs } else { value *= rhs }
            }
            return value
        }

        // factor = number | '(' expression ')' | '-' factor
        private mutating func parseFactor() -> Double? {
            guard let token = peek() else { return nil }
            if token == "-" { _ = advance(); guard let f = parseFactor() else { return nil }; return -f }
            if token == "(" {
                _ = advance()
                guard let value = parseExpression(), peek() == ")" else { return nil }
                _ = advance()
                return value
            }
            if let number = Double(token) { _ = advance(); return number }
            return nil
        }
    }
}
