package ai.quenderin.core

import kotlin.math.abs
import kotlin.math.pow

/**
 * A capability the agent can invoke during its loop. On-device and offline — math, text
 * utilities, local search, etc. Synchronous here (the Kotlin core is coroutine-free); the
 * app wraps long-running tools in a coroutine. Mirrors iOS `AgentTool`.
 *
 * Deliberately NOT "drive another app": the OS sandboxes apps from controlling each other,
 * so the agent acts through *tools* it owns — the honest, shippable shape of "autonomous".
 */
interface AgentTool {
    /** Stable identifier the planner emits, e.g. "calculator". */
    val name: String
    /** One line the planner sees to decide when to use it. */
    val purpose: String
    /** Run with a string input, returning an observation string. */
    fun run(input: String): String
}

/** Returns its input verbatim — deterministic, the simplest possible example. */
class EchoTool : AgentTool {
    override val name = "echo"
    override val purpose = "Repeat the input back. Use to restate something."
    override fun run(input: String): String = input
}

/** Evaluates simple arithmetic. Uses a hand-rolled recursive-descent parser that returns
 *  null on malformed input rather than throwing — the input comes from an LLM. */
class CalculatorTool : AgentTool {
    override val name = "calculator"
    override val purpose = "Evaluate arithmetic like \"12 * (3 + 4)\" or \"2^10\" (supports + - * / ^ and parentheses)."
    override fun run(input: String): String {
        val value = ArithmeticParser.evaluate(input) ?: return "Couldn't evaluate \"$input\"."
        return if (value == Math.rint(value) && abs(value) < 1e15) value.toLong().toString() else value.toString()
    }
}

/** Tiny, safe arithmetic evaluator (`+ - * /`, parentheses, unary minus, decimals). */
object ArithmeticParser {
    fun evaluate(text: String): Double? {
        val tokens = tokenize(text) ?: return null
        val parser = Parser(tokens)
        val value = parser.parseExpression() ?: return null
        // reject NaN/Inf (e.g. (-2)^0.5, 2^9999) → "Couldn't evaluate", not "NaN"/"Infinity"
        return if (parser.isAtEnd && value.isFinite()) value else null
    }

    private fun tokenize(text: String): List<String>? {
        val tokens = mutableListOf<String>()
        var number = StringBuilder()
        for (c in text) {
            if (c.isWhitespace()) continue
            if (c.isDigit() || c == '.') {
                number.append(c)
            } else {
                if (number.isNotEmpty()) { tokens.add(number.toString()); number = StringBuilder() }
                if (c in "+-*/^()") tokens.add(c.toString()) else return null
            }
        }
        if (number.isNotEmpty()) tokens.add(number.toString())
        return tokens
    }

    private class Parser(val tokens: List<String>) {
        var pos = 0
        val isAtEnd: Boolean get() = pos >= tokens.size
        private fun peek(): String? = tokens.getOrNull(pos)
        private fun advance() { pos++ }

        // expression = term (('+' | '-') term)*
        fun parseExpression(depth: Int = 0): Double? {
            if (depth > MAX_DEPTH) return null  // cap recursion — parity with the Swift twin (C4)
            var value = parseTerm(depth + 1) ?: return null
            while (true) {
                val op = peek()
                if (op != "+" && op != "-") break
                advance()
                val rhs = parseTerm(depth + 1) ?: return null
                value = if (op == "+") value + rhs else value - rhs
            }
            return value
        }

        // term = factor (('*' | '/') factor)*
        private fun parseTerm(depth: Int): Double? {
            if (depth > MAX_DEPTH) return null
            var value = parseFactor(depth + 1) ?: return null
            while (true) {
                val op = peek()
                if (op != "*" && op != "/") break
                advance()
                val rhs = parseFactor(depth + 1) ?: return null
                if (op == "/") {
                    if (rhs == 0.0) return null
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        // factor = '-' factor | power   (unary minus binds LOOSER than '^', so -2^2 = -(2^2) = -4)
        private fun parseFactor(depth: Int): Double? {
            if (depth > MAX_DEPTH) return null
            if (peek() == "-") { advance(); val f = parseFactor(depth + 1) ?: return null; return -f }
            return parsePower(depth + 1)
        }

        // power = primary ('^' factor)?   (right-associative, binds TIGHTER than '*'/'/': 2^3^2 = 2^9,
        // 2*3^2 = 2*9; the RHS recurses through factor so a unary/negative exponent like 2^-1 works)
        private fun parsePower(depth: Int): Double? {
            if (depth > MAX_DEPTH) return null
            val base = parsePrimary(depth + 1) ?: return null
            if (peek() != "^") return base
            advance()
            val exponent = parseFactor(depth + 1) ?: return null
            return base.pow(exponent)
        }

        // primary = number | '(' expression ')'
        private fun parsePrimary(depth: Int): Double? {
            if (depth > MAX_DEPTH) return null
            val token = peek() ?: return null
            if (token == "(") {
                advance()
                val value = parseExpression(depth + 1) ?: return null
                if (peek() != ")") return null
                advance()
                return value
            }
            val number = token.toDoubleOrNull() ?: return null
            advance()
            return number
        }

        private companion object { const val MAX_DEPTH = 100 }
    }
}
