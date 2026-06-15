import { describe, it, expect } from 'vitest';
import { safeCalculate, CalculatorError } from '../src/services/tools/calculator.js';

// The "no eval()" safe calculator is a headline correctness feature but shipped with zero
// tests (audit H13). These pin down the arithmetic AND the trailing-garbage guard (audit H6).
describe('safeCalculate', () => {
    it('evaluates basic arithmetic with precedence', () => {
        expect(safeCalculate('2 + 2')).toBe(4);
        expect(safeCalculate('2 + 3 * 4')).toBe(14);
        expect(safeCalculate('(2 + 3) * 4')).toBe(20);
        expect(safeCalculate('10 / 4')).toBe(2.5);
        expect(safeCalculate('-5 + 3')).toBe(-2);
    });

    it('evaluates supported functions', () => {
        expect(safeCalculate('sqrt(9)')).toBe(3);
        expect(safeCalculate('abs(-7)')).toBe(7);
        expect(safeCalculate('floor(2.7)')).toBe(2);
        expect(safeCalculate('ceil(2.1)')).toBe(3);
        expect(safeCalculate('round(2.5)')).toBe(3);
    });

    // H6: tokenizable-but-unconsumed trailing input must error, not silently return a partial answer.
    // (Whitespace is stripped before tokenizing, so these use tokens that remain *after* a complete
    // parse — e.g. "(1+2)4" leaves a trailing "4"; "2 3" would collapse to the number 23, not garbage.)
    it('rejects trailing garbage instead of returning a partial result', () => {
        expect(() => safeCalculate('(1 + 2) 4')).toThrow(CalculatorError); // -> "(1+2)4", trailing 4
        expect(() => safeCalculate('2 ) (')).toThrow(CalculatorError);      // -> "2)(", trailing )
        expect(() => safeCalculate('1 + 2 )')).toThrow(CalculatorError);    // -> "1+2)", trailing )
        expect(() => safeCalculate('3 (4)')).toThrow(CalculatorError);      // -> "3(4)", trailing (
    });

    it('rejects empty, oversized, and malformed expressions', () => {
        expect(() => safeCalculate('')).toThrow(CalculatorError);
        expect(() => safeCalculate('   ')).toThrow(CalculatorError);
        expect(() => safeCalculate('1 +')).toThrow(CalculatorError);
        expect(() => safeCalculate('bogus(2)')).toThrow(CalculatorError);
        expect(() => safeCalculate('1'.repeat(501))).toThrow(CalculatorError);
    });

    it('rejects non-finite results', () => {
        expect(() => safeCalculate('1 / 0')).toThrow(CalculatorError);
    });
});
