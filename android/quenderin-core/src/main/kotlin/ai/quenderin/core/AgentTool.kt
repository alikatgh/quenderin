package ai.quenderin.core

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.pow
import kotlin.math.sqrt

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
class EchoTool : Capability {
    override val name = "echo"
    override val purpose = "Repeat the input back. Use to restate something."
    override fun run(input: String): String = input
}

/** Evaluates simple arithmetic. Uses a hand-rolled recursive-descent parser that returns
 *  null on malformed input rather than throwing — the input comes from an LLM. */
class CalculatorTool : Capability {
    override val name = "calculator"
    override val purpose = "Evaluate arithmetic like \"12 * (3 + 4)\", \"2^10\", or \"sqrt(16)\" (+ - * / ^ %, parentheses, sqrt/abs/floor/ceil, pi/e)."
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
        var ident = StringBuilder()   // a function name (sqrt) or constant (pi) — runs of letters
        fun flush() {
            if (number.isNotEmpty()) { tokens.add(number.toString()); number = StringBuilder() }
            if (ident.isNotEmpty()) { tokens.add(ident.toString()); ident = StringBuilder() }
        }
        for (c in text) {
            if (c.isWhitespace()) continue
            when {
                c.isDigit() || c == '.' -> { if (ident.isNotEmpty()) flush(); number.append(c) }
                c.isLetter() -> { if (number.isNotEmpty()) flush(); ident.append(c.lowercaseChar()) }
                else -> {
                    flush()
                    if (c in "+-*/^%()") tokens.add(c.toString()) else return null
                }
            }
        }
        flush()
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

        // term = factor (('*' | '/' | '%') factor)*
        private fun parseTerm(depth: Int): Double? {
            if (depth > MAX_DEPTH) return null
            var value = parseFactor(depth + 1) ?: return null
            while (true) {
                val op = peek()
                if (op != "*" && op != "/" && op != "%") break
                advance()
                val rhs = parseFactor(depth + 1) ?: return null
                when (op) {
                    "/" -> { if (rhs == 0.0) return null; value /= rhs }
                    "%" -> { if (rhs == 0.0) return null; value %= rhs }
                    else -> value *= rhs
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

        // primary = number | constant | function '(' expression ')' | '(' expression ')'
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
            val fn = FUNCTIONS[token]
            if (fn != null) {                            // function call: name '(' expr ')'
                advance()
                if (peek() != "(") return null
                advance()
                val arg = parseExpression(depth + 1) ?: return null
                if (peek() != ")") return null
                advance()
                return fn(arg)
            }
            CONSTANTS[token]?.let { advance(); return it }
            val number = token.toDoubleOrNull() ?: return null
            advance()
            return number
        }

        private companion object {
            const val MAX_DEPTH = 100
            // Parity-safe single-arg functions + constants — IDENTICAL across Swift/Kotlin/JS. NOT
            // round/log/ln/sin/cos/tan (their half-rounding + domain/precision behavior differs across
            // stdlibs, which would re-introduce the cross-platform divergences this project keeps fixing).
            val FUNCTIONS: Map<String, (Double) -> Double> = mapOf(
                "sqrt" to { x: Double -> sqrt(x) }, "abs" to { x: Double -> abs(x) },
                "floor" to { x: Double -> floor(x) }, "ceil" to { x: Double -> ceil(x) },
            )
            val CONSTANTS: Map<String, Double> = mapOf("pi" to Math.PI, "e" to Math.E)
        }
    }
}
