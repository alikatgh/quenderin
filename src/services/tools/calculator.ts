/**
 * Safe Calculator — Recursive Descent Parser (NO eval())
 *
 * Ported from off-grid-mobile's safe math evaluation approach.
 * Supports: +, -, *, /, ^, %, (), sqrt(), abs(), sin(), cos(), tan(), log(), ln(), pi, e
 */

export class CalculatorError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'CalculatorError';
    }
}

interface Token {
    type: 'number' | 'operator' | 'paren' | 'function' | 'constant';
    value: string;
}

const FUNCTIONS = ['sqrt', 'abs', 'sin', 'cos', 'tan', 'log', 'ln', 'ceil', 'floor', 'round'];
const CONSTANTS: Record<string, number> = {
    'pi': Math.PI,
    'e': Math.E,
};

/** Tokenize math expression */
function tokenize(expr: string): Token[] {
    const tokens: Token[] = [];
    let i = 0;
    const s = expr.replace(/\s+/g, '');

    while (i < s.length) {
        // Numbers (including decimals)
        if (/[\d.]/.test(s[i])) {
            let num = '';
            while (i < s.length && /[\d.]/.test(s[i])) {
                num += s[i++];
            }
            // Reject malformed numbers with >1 decimal point. parseFloat('1.2.3') silently returns 1.2
            // (NOT NaN), so without this a typo'd literal would evaluate to a wrong answer instead of an
            // error — unacceptable for a calculator (deep-hunt).
            if ((num.match(/\./g) || []).length > 1) {
                throw new CalculatorError(`Invalid number: ${num}`);
            }
            tokens.push({ type: 'number', value: num });
            continue;
        }

        // Parentheses
        if (s[i] === '(' || s[i] === ')') {
            tokens.push({ type: 'paren', value: s[i++] });
            continue;
        }

        // Operators
        if ('+-*/%^'.includes(s[i])) {
            tokens.push({ type: 'operator', value: s[i++] });
            continue;
        }

        // Functions and constants (alpha characters)
        if (/[a-zA-Z]/.test(s[i])) {
            let word = '';
            while (i < s.length && /[a-zA-Z]/.test(s[i])) {
                word += s[i++];
            }
            const lower = word.toLowerCase();
            if (FUNCTIONS.includes(lower)) {
                tokens.push({ type: 'function', value: lower });
            } else if (lower in CONSTANTS) {
                tokens.push({ type: 'constant', value: lower });
            } else {
                throw new CalculatorError(`Unknown identifier: ${word}`);
            }
            continue;
        }

        throw new CalculatorError(`Unexpected character: ${s[i]}`);
    }

    return tokens;
}

/** Recursive descent parser + evaluator */
class Parser {
    private pos = 0;
    private tokens: Token[];

    constructor(tokens: Token[]) {
        this.tokens = tokens;
    }

    private peek(): Token | null {
        return this.pos < this.tokens.length ? this.tokens[this.pos] : null;
    }

    /** True once every token has been consumed — used to reject trailing garbage. */
    atEnd(): boolean {
        return this.pos >= this.tokens.length;
    }

    private consume(): Token {
        if (this.pos >= this.tokens.length) {
            throw new CalculatorError('Unexpected end of expression');
        }
        return this.tokens[this.pos++];
    }

    /** expression = term (('+' | '-') term)* */
    parseExpression(): number {
        let result = this.parseTerm();
        while (this.peek()?.type === 'operator' && (this.peek()!.value === '+' || this.peek()!.value === '-')) {
            const op = this.consume().value;
            const right = this.parseTerm();
            result = op === '+' ? result + right : result - right;
        }
        return result;
    }

    /** term = unary (('*' | '/' | '%') unary)* */
    private parseTerm(): number {
        let result = this.parseUnary();
        while (this.peek()?.type === 'operator' && ('*/%'.includes(this.peek()!.value))) {
            const op = this.consume().value;
            const right = this.parseUnary();
            if (op === '*') result *= right;
            else if (op === '/') {
                if (right === 0) throw new CalculatorError('Division by zero');
                result /= right;
            }
            else result %= right;
        }
        return result;
    }

    /**
     * unary = ('+' | '-') unary | exponent
     * Unary minus binds LOOSER than '^', so -2^2 = -(2^2) = -4 — the standard math convention
     * (Python/Wolfram/TI; Excel's (-2)^2=4 is the outlier). This matches the iOS/Android twins'
     * ArithmeticParser exactly; previously this was inside parseExponent and gave -2^2 = 4.
     */
    private parseUnary(): number {
        if (this.peek()?.type === 'operator' && (this.peek()!.value === '+' || this.peek()!.value === '-')) {
            const op = this.consume().value;
            const val = this.parseUnary();
            return op === '-' ? -val : val;
        }
        return this.parseExponent();
    }

    /** exponent = primary ('^' unary)?   (right-associative; binds TIGHTER than unary minus) */
    private parseExponent(): number {
        const base = this.parsePrimary();
        if (this.peek()?.type === 'operator' && this.peek()!.value === '^') {
            this.consume();
            const right = this.parseUnary(); // RHS via unary → right-associative + negative exponents (2^-1)
            return Math.pow(base, right);
        }
        return base;
    }

    /** primary = number | constant | function '(' expr ')' | '(' expr ')' */
    private parsePrimary(): number {
        const token = this.peek();

        if (!token) throw new CalculatorError('Unexpected end of expression');

        // Number
        if (token.type === 'number') {
            this.consume();
            const n = parseFloat(token.value);
            if (isNaN(n)) throw new CalculatorError(`Invalid number: ${token.value}`);
            return n;
        }

        // Constant
        if (token.type === 'constant') {
            this.consume();
            return CONSTANTS[token.value];
        }

        // Function call
        if (token.type === 'function') {
            this.consume();
            const open = this.consume();
            if (open.type !== 'paren' || open.value !== '(') {
                throw new CalculatorError(`Expected '(' after function ${token.value}`);
            }
            const arg = this.parseExpression();
            const close = this.consume();
            if (close.type !== 'paren' || close.value !== ')') {
                throw new CalculatorError(`Expected ')' after function argument`);
            }
            return this.applyFunction(token.value, arg);
        }

        // Parenthesized expression
        if (token.type === 'paren' && token.value === '(') {
            this.consume();
            const result = this.parseExpression();
            const close = this.consume();
            if (close.type !== 'paren' || close.value !== ')') {
                throw new CalculatorError('Mismatched parentheses');
            }
            return result;
        }

        throw new CalculatorError(`Unexpected token: ${token.value}`);
    }

    private applyFunction(name: string, arg: number): number {
        switch (name) {
            case 'sqrt': return Math.sqrt(arg);
            case 'abs': return Math.abs(arg);
            case 'sin': return Math.sin(arg);
            case 'cos': return Math.cos(arg);
            case 'tan': return Math.tan(arg);
            case 'log': return Math.log10(arg);
            case 'ln': return Math.log(arg);
            case 'ceil': return Math.ceil(arg);
            case 'floor': return Math.floor(arg);
            case 'round': return Math.round(arg);
            default: throw new CalculatorError(`Unknown function: ${name}`);
        }
    }
}

/** Safely evaluate a math expression — no eval() */
export function safeCalculate(expression: string): number {
    if (expression.length > 500) {
        throw new CalculatorError('Expression too long (max 500 chars)');
    }
    const tokens = tokenize(expression);
    if (tokens.length === 0) {
        throw new CalculatorError('Empty expression');
    }
    const parser = new Parser(tokens);
    const result = parser.parseExpression();
    // Reject tokenizable-but-unconsumed trailing input (e.g. "2 3", "(1+2) 4") instead of
    // silently returning a partial answer — for a calculator, a wrong number is worse than an error.
    if (!parser.atEnd()) {
        throw new CalculatorError('Unexpected trailing input in expression');
    }
    if (!isFinite(result)) {
        throw new CalculatorError('Result is not finite');
    }
    return result;
}

/**
 * ONE number→string rendering for tool observations, byte-identical across the twins
 * (Swift NumberRender in apple/.../AgentTool.swift, Kotlin NumberRender in
 * android/.../AgentTool.kt) — platform-native shortest-repr strings diverge in digits AND
 * presentation ("1.1805916207174113e+21" here vs "1.18…E21" on Android), feeding the agent
 * loop different observations for the same value (twin-drift audit, agent-session P2).
 * Contract: 12 significant digits with HALF-EVEN ties on the EXACT decimal expansion of the
 * double (BigDecimal on Android, C's correctly-rounded %.11e on iOS — JS toExponential breaks
 * decimal ties by picking the LARGER digit, so it cannot be used here), plain decimal for
 * exponents -5…14, canonical scientific ("1.18059162072e+21") outside.
 */
export function renderCalcResult(v: number): string {
    // Render integers without a trailing .0 — same shortcut as the twins' CalculatorTool.run.
    if (Math.round(v) === v && Math.abs(v) < 1e15) return String(v);
    return canonicalNumber(v);
}

function canonicalNumber(v: number): string {
    if (!Number.isFinite(v)) return String(v);
    if (v === 0) return '0';

    // Exact decimal expansion of the double: v = ±m × 2^e with m, e from the IEEE-754 bits.
    const view = new DataView(new ArrayBuffer(8));
    view.setFloat64(0, v);
    const bits = view.getBigUint64(0);
    const sign = bits >> 63n ? '-' : '';
    const expBits = Number((bits >> 52n) & 0x7ffn);
    const fracBits = bits & 0xfffffffffffffn;
    const m = expBits === 0 ? fracBits : fracBits | (1n << 52n);
    const e = expBits === 0 ? -1074 : expBits - 1075;

    // m × 2^e as unscaled × 10^-scale (exact): e ≥ 0 shifts into the integer; e < 0 uses 2^-k = 5^k/10^k.
    let unscaled = e >= 0 ? m << BigInt(e) : m * 5n ** BigInt(-e);
    let scale = e >= 0 ? 0 : -e;

    // Round to 12 significant digits, HALF-EVEN — the BigDecimal MathContext(12, HALF_EVEN) twin.
    let digits = unscaled.toString();
    if (digits.length > 12) {
        const rest = digits.slice(12);
        scale -= rest.length;
        let kept = BigInt(digits.slice(0, 12));
        const restNum = BigInt(rest);
        const half = 5n * 10n ** BigInt(rest.length - 1);
        if (restNum > half || (restNum === half && kept % 2n === 1n)) kept += 1n;
        digits = kept.toString(); // a 999…→1000… rollover just adds a trailing zero; assemble handles it
    }

    // The shared presentation half — same tokens as the Swift/Kotlin assemble().
    const exponent = digits.length - 1 - scale;
    digits = digits.replace(/0+$/, '') || '0';
    if (exponent >= -5 && exponent <= 14) {
        if (exponent >= digits.length - 1) return sign + digits + '0'.repeat(exponent - (digits.length - 1));
        if (exponent >= 0) return sign + digits.slice(0, exponent + 1) + '.' + digits.slice(exponent + 1);
        return sign + '0.' + '0'.repeat(-exponent - 1) + digits;
    }
    const mantissa = digits.length === 1 ? digits : digits[0] + '.' + digits.slice(1);
    return `${sign}${mantissa}e${exponent >= 0 ? '+' : '-'}${Math.abs(exponent)}`;
}
