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
    public let purpose = "Evaluate arithmetic like \"12 * (3 + 4)\", \"2^10\", or \"sqrt(16)\" (+ - * / ^ %, parentheses, sqrt/abs/floor/ceil, pi/e)."

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
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return value   // reject NaN/Inf (e.g. (-2)^0.5, 2^9999) → "Couldn't evaluate", not "nan"/"inf"
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var number = ""
        var ident = ""   // a function name (sqrt) or constant (pi) — runs of letters
        func flush() {
            if !number.isEmpty { tokens.append(number); number = "" }
            if !ident.isEmpty { tokens.append(ident); ident = "" }
        }
        for char in text where !char.isWhitespace {
            if char.isNumber || char == "." {
                if !ident.isEmpty { flush() }        // letter→digit boundary
                number.append(char)
            } else if char.isLetter {
                if !number.isEmpty { flush() }        // digit→letter boundary
                ident += String(char).lowercased()
            } else {
                flush()
                if "+-*/^%()".contains(char) { tokens.append(String(char)) } else { return [] }
            }
        }
        flush()
        return tokens
    }

    private struct Parser {
        let tokens: [String]
        var pos = 0
        var isAtEnd: Bool { pos >= tokens.count }
        private func peek() -> String? { pos < tokens.count ? tokens[pos] : nil }
        private mutating func advance() -> String? { defer { pos += 1 }; return peek() }

        // A recursion-depth cap: a Swift stack overflow is NOT a catchable Error, so deeply
        // nested parens (e.g. adversarial model output) would hard-crash the process instead of
        // failing the calc gracefully. Bail to nil past this depth (C4; mirrors the Kotlin twin).
        private static let maxDepth = 100

        // expression = term (('+' | '-') term)*
        mutating func parseExpression(_ depth: Int = 0) -> Double? {
            if depth > Self.maxDepth { return nil }
            guard var value = parseTerm(depth + 1) else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                _ = advance()
                guard let rhs = parseTerm(depth + 1) else { return nil }
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        // term = factor (('*' | '/' | '%') factor)*
        private mutating func parseTerm(_ depth: Int) -> Double? {
            if depth > Self.maxDepth { return nil }
            guard var value = parseFactor(depth + 1) else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                _ = advance()
                guard let rhs = parseFactor(depth + 1) else { return nil }
                switch op {
                case "/": guard rhs != 0 else { return nil }; value /= rhs
                case "%": guard rhs != 0 else { return nil }; value = value.truncatingRemainder(dividingBy: rhs)
                default:  value *= rhs
                }
            }
            return value
        }

        // factor = '-' factor | power   (unary minus binds LOOSER than '^', so -2^2 = -(2^2) = -4)
        private mutating func parseFactor(_ depth: Int) -> Double? {
            if depth > Self.maxDepth { return nil }
            if peek() == "-" { _ = advance(); guard let f = parseFactor(depth + 1) else { return nil }; return -f }
            return parsePower(depth + 1)
        }

        // power = primary ('^' factor)?   (right-associative, binds TIGHTER than '*'/'/': 2^3^2 = 2^9,
        // 2*3^2 = 2*9; the RHS recurses through factor so a unary/negative exponent like 2^-1 works)
        private mutating func parsePower(_ depth: Int) -> Double? {
            if depth > Self.maxDepth { return nil }
            guard let base = parsePrimary(depth + 1) else { return nil }
            guard peek() == "^" else { return base }
            _ = advance()
            guard let exponent = parseFactor(depth + 1) else { return nil }
            return pow(base, exponent)
        }

        // Parity-safe single-arg functions + constants — IDENTICAL across Swift/Kotlin/JS. Deliberately
        // NOT round / log / ln / sin / cos / tan: their half-rounding + domain/precision behavior differs
        // across stdlibs, which would re-introduce the cross-platform divergences this project keeps fixing.
        private static let functions: [String: @Sendable (Double) -> Double] = [
            "sqrt": { Foundation.sqrt($0) }, "abs": { Swift.abs($0) },
            "floor": { Foundation.floor($0) }, "ceil": { Foundation.ceil($0) },
        ]
        private static let constants: [String: Double] = ["pi": .pi, "e": M_E]

        // primary = number | constant | function '(' expression ')' | '(' expression ')'
        private mutating func parsePrimary(_ depth: Int) -> Double? {
            if depth > Self.maxDepth { return nil }
            guard let token = peek() else { return nil }
            if token == "(" {
                _ = advance()
                guard let value = parseExpression(depth + 1), peek() == ")" else { return nil }
                _ = advance()
                return value
            }
            if let fn = Self.functions[token] {                       // function call: name '(' expr ')'
                _ = advance()
                guard peek() == "(" else { return nil }
                _ = advance()
                guard let arg = parseExpression(depth + 1), peek() == ")" else { return nil }
                _ = advance()
                return fn(arg)
            }
            if let constant = Self.constants[token] { _ = advance(); return constant }
            if let number = Double(token) { _ = advance(); return number }
            return nil
        }
    }
}
