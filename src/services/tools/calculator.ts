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

    /** term = exponent (('*' | '/' | '%') exponent)* */
    private parseTerm(): number {
        let result = this.parseExponent();
        while (this.peek()?.type === 'operator' && ('*/%'.includes(this.peek()!.value))) {
            const op = this.consume().value;
            const right = this.parseExponent();
            if (op === '*') result *= right;
            else if (op === '/') {
                if (right === 0) throw new CalculatorError('Division by zero');
                result /= right;
            }
            else result %= right;
        }
        return result;
    }

    /** exponent = unary ('^' unary)* (right-associative) */
    private parseExponent(): number {
        let result = this.parseUnary();
        if (this.peek()?.type === 'operator' && this.peek()!.value === '^') {
            this.consume();
            const right = this.parseExponent(); // right-associative recursion
            result = Math.pow(result, right);
        }
        return result;
    }

    /** unary = ('+' | '-')? primary */
    private parseUnary(): number {
        if (this.peek()?.type === 'operator' && (this.peek()!.value === '+' || this.peek()!.value === '-')) {
            const op = this.consume().value;
            const val = this.parsePrimary();
            return op === '-' ? -val : val;
        }
        return this.parsePrimary();
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
    if (!isFinite(result)) {
        throw new CalculatorError('Result is not finite');
    }
    return result;
}
