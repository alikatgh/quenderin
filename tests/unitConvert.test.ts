import { describe, it, expect } from 'vitest';
import {
    parseConversion,
    convertUnits,
    formatUnitValue,
    canonicalUnit,
    runUnitConversion,
} from '../src/services/tools/unitConvert.js';
import { executeTool } from '../src/services/tools/handlers.js';
import { AVAILABLE_TOOLS } from '../src/services/tools/registry.js';

// The unit_convert tool is a fully-offline, pure-logic addition to the desktop chat
// tool loop, mirroring the native mobile UnitConverter so all three platforms agree.
// These pin the engine math AND the real handler wiring (import the shipped exports,
// assert the real values — per the bug-journal "Test ≠ shipped code" pattern).

describe('unitConvert — parseConversion', () => {
    it('parses "<value> <from> to <to>"', () => {
        expect(parseConversion('20 km to mi')).toEqual({ value: 20, from: 'km', to: 'mi' });
        expect(parseConversion('5 kg to lb')).toEqual({ value: 5, from: 'kg', to: 'lb' });
    });

    it('accepts "in" as the separator too', () => {
        expect(parseConversion('30 C in F')).toEqual({ value: 30, from: 'c', to: 'f' });
    });

    it('splits on the FIRST separator so "in" as a unit survives', () => {
        // The right side "to ft" → ft; the left "5 in" → inches. A naive " in "
        // split would wrongly carve up the "in" unit.
        expect(parseConversion('5 in to ft')).toEqual({ value: 5, from: 'in', to: 'ft' });
    });

    it('normalizes spelled-out and alternate-spelling units', () => {
        expect(parseConversion('3 miles to kilometers')).toEqual({ value: 3, from: 'mi', to: 'km' });
        expect(parseConversion('2 pounds to grams')).toEqual({ value: 2, from: 'lb', to: 'g' });
        expect(parseConversion('100 km/h to mph')).toEqual({ value: 100, from: 'kph', to: 'mph' });
    });

    it('handles decimal and negative values', () => {
        expect(parseConversion('1.5 m to cm')).toEqual({ value: 1.5, from: 'm', to: 'cm' });
        expect(parseConversion('-40 C to F')).toEqual({ value: -40, from: 'c', to: 'f' });
    });

    it('returns null for input with no recognizable shape', () => {
        expect(parseConversion('hello world')).toBeNull();
        expect(parseConversion('convert stuff')).toBeNull();
        expect(parseConversion('km to mi')).toBeNull(); // no number
        expect(parseConversion('20 km')).toBeNull();    // no separator
    });
});

describe('unitConvert — canonicalUnit', () => {
    it('maps aliases to canonical symbols', () => {
        expect(canonicalUnit('Kilometers')).toBe('km');
        expect(canonicalUnit(' FEET ')).toBe('ft');
        expect(canonicalUnit('celsius')).toBe('c');
        expect(canonicalUnit('m/s')).toBe('mps');
    });

    it('passes through an already-canonical symbol', () => {
        expect(canonicalUnit('kg')).toBe('kg');
    });
});

describe('unitConvert — convertUnits', () => {
    it('converts within the length dimension', () => {
        expect(convertUnits(1, 'km', 'm')).toBe(1000);
        expect(convertUnits(100, 'cm', 'm')).toBe(1);
        expect(convertUnits(1, 'mi', 'km')).toBeCloseTo(1.609344, 6);
    });

    it('converts within the mass dimension', () => {
        expect(convertUnits(1, 'kg', 'g')).toBe(1000);
        expect(convertUnits(1, 'lb', 'g')).toBeCloseTo(453.59237, 5);
    });

    it('converts within the volume and speed dimensions', () => {
        expect(convertUnits(1, 'l', 'ml')).toBe(1000);
        expect(convertUnits(1, 'gal', 'l')).toBeCloseTo(3.785411784, 6);
        expect(convertUnits(1, 'mph', 'kph')).toBeCloseTo(1.609344, 4);
    });

    it('handles affine temperature conversions', () => {
        expect(convertUnits(0, 'c', 'f')).toBe(32);
        expect(convertUnits(100, 'c', 'f')).toBe(212);
        expect(convertUnits(-40, 'c', 'f')).toBe(-40); // the famous crossover
        expect(convertUnits(0, 'c', 'k')).toBeCloseTo(273.15, 2);
        expect(convertUnits(32, 'f', 'c')).toBe(0);
    });

    it('refuses cross-dimension conversions', () => {
        expect(convertUnits(5, 'kg', 'm')).toBeNull();
        expect(convertUnits(20, 'c', 'km')).toBeNull(); // temp vs length
        expect(convertUnits(10, 'l', 'kg')).toBeNull();
    });

    it('returns null for unknown units', () => {
        expect(convertUnits(5, 'furlong', 'm')).toBeNull();
        expect(convertUnits(5, 'm', 'parsec')).toBeNull();
    });
});

describe('unitConvert — formatUnitValue', () => {
    it('keeps integers as integers', () => {
        expect(formatUnitValue(1000)).toBe('1000');
        expect(formatUnitValue(-40)).toBe('-40');
    });

    it('rounds to at most 4 decimal places', () => {
        expect(formatUnitValue(1.609344)).toBe('1.6093');
        expect(formatUnitValue(0.5)).toBe('0.5');
    });
});

describe('unitConvert — runUnitConversion (string entry point)', () => {
    it('returns a human-readable conversion line', () => {
        expect(runUnitConversion('1 km to m')).toBe('1 km = 1000 m');
        expect(runUnitConversion('100 C to F')).toBe('100 c = 212 f');
    });

    it('degrades unparseable input to a hint, never throwing', () => {
        expect(runUnitConversion('what is the meaning of life')).toContain("Couldn't read a conversion");
    });

    it('explains a cross-dimension mismatch', () => {
        expect(runUnitConversion('5 kg to m')).toContain('measure different things');
    });
});

describe('unitConvert — wired into the chat tool handler', () => {
    it('is registered with an "expression" parameter', () => {
        const def = AVAILABLE_TOOLS.find(t => t.name === 'unit_convert');
        expect(def).toBeDefined();
        const paramNames = (def?.parameters ?? []).map(p => p.name);
        expect(paramNames).toContain('expression');
    });

    it('executes through the real executeTool dispatcher', async () => {
        const res = await executeTool({ tool: 'unit_convert', args: { expression: '2 kg to lb' } });
        expect(res.success).toBe(true);
        expect(res.result).toBe('2 kg = 4.4092 lb');
    });

    it('errors on a missing expression argument', async () => {
        const res = await executeTool({ tool: 'unit_convert', args: {} });
        expect(res.success).toBe(false);
        expect(res.error).toMatch(/Missing expression/);
    });
});
