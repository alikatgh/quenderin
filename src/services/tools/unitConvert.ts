/**
 * Unit Converter — fully offline, pure-logic unit conversion.
 *
 * Mirrors the native mobile engine (`apple/QuenderinKit/.../AgentToolsExtra.swift`
 * `UnitConverter`, and the Android Kotlin `UnitConverterTool`) so all three
 * platforms convert identically. Linear units convert through a per-dimension
 * base unit; temperature is affine and handled on its own. Cross-dimension or
 * unknown requests return null rather than guessing — the LLM's input is never
 * trusted.
 *
 * Parses natural phrasing the local model emits: "20 km to mi", "30 C in F",
 * "5 kg to lb".
 */

export interface UnitConvertRequest {
    value: number;
    from: string;
    to: string;
}

// canonical unit symbol → (dimension, factor to the dimension's base unit)
const LINEAR: Record<string, { dim: string; toBase: number }> = {
    // length — base: metre
    m: { dim: 'len', toBase: 1 },
    km: { dim: 'len', toBase: 1000 },
    cm: { dim: 'len', toBase: 0.01 },
    mm: { dim: 'len', toBase: 0.001 },
    mi: { dim: 'len', toBase: 1609.344 },
    ft: { dim: 'len', toBase: 0.3048 },
    in: { dim: 'len', toBase: 0.0254 },
    yd: { dim: 'len', toBase: 0.9144 },
    // mass — base: gram
    g: { dim: 'mass', toBase: 1 },
    kg: { dim: 'mass', toBase: 1000 },
    mg: { dim: 'mass', toBase: 0.001 },
    lb: { dim: 'mass', toBase: 453.59237 },
    oz: { dim: 'mass', toBase: 28.349523125 },
    // volume — base: litre
    l: { dim: 'vol', toBase: 1 },
    ml: { dim: 'vol', toBase: 0.001 },
    gal: { dim: 'vol', toBase: 3.785411784 },
    floz: { dim: 'vol', toBase: 0.0295735295625 },
    // speed — base: metre/second
    mps: { dim: 'spd', toBase: 1 },
    kph: { dim: 'spd', toBase: 0.277777778 },
    mph: { dim: 'spd', toBase: 0.44704 },
};

// spelled-out / alternate spellings → canonical symbol
const ALIAS: Record<string, string> = {
    meter: 'm', meters: 'm', metre: 'm', metres: 'm',
    kilometer: 'km', kilometers: 'km', kilometre: 'km', kilometres: 'km',
    centimeter: 'cm', centimeters: 'cm', millimeter: 'mm', millimeters: 'mm',
    mile: 'mi', miles: 'mi', foot: 'ft', feet: 'ft',
    inch: 'in', inches: 'in', yard: 'yd', yards: 'yd',
    gram: 'g', grams: 'g', kilogram: 'kg', kilograms: 'kg', kilo: 'kg', kilos: 'kg',
    milligram: 'mg', milligrams: 'mg', pound: 'lb', pounds: 'lb', lbs: 'lb',
    ounce: 'oz', ounces: 'oz',
    liter: 'l', liters: 'l', litre: 'l', litres: 'l',
    milliliter: 'ml', milliliters: 'ml', millilitre: 'ml', millilitres: 'ml',
    gallon: 'gal', gallons: 'gal',
    celsius: 'c', centigrade: 'c', fahrenheit: 'f', kelvin: 'k',
    kmh: 'kph', 'km/h': 'kph', 'mi/h': 'mph', 'm/s': 'mps',
};

const TEMPS = new Set(['c', 'f', 'k']);

/** Normalize a unit token to its canonical symbol. */
export function canonicalUnit(unit: string): string {
    const u = unit.toLowerCase().trim();
    return ALIAS[u] ?? u;
}

/**
 * Parse a free-text request like "20 km to mi" / "30 C in F" into a structured
 * request. Returns null if no "X <unit> to/in <unit>" shape is present.
 */
export function parseConversion(text: string): UnitConvertRequest | null {
    const lower = text.toLowerCase();
    let sep: string;
    if (lower.includes(' to ')) sep = ' to ';
    else if (lower.includes(' in ')) sep = ' in ';
    else return null;

    // Split on the FIRST separator only, so "5 in to ft" (inches→feet) keeps the
    // trailing unit intact rather than being chopped by a second " in ".
    const sepIdx = lower.indexOf(sep);
    const leftPart = lower.slice(0, sepIdx).trim();
    const rightPart = lower.slice(sepIdx + sep.length).trim();
    if (!leftPart || !rightPart) return null;

    const toUnit = canonicalUnit(rightPart);

    // Read a leading signed/decimal number off the left, then the unit that follows.
    let numStr = '';
    let idx = 0;
    while (idx < leftPart.length) {
        const ch = leftPart[idx];
        if (/[0-9.]/.test(ch) || (ch === '-' && numStr === '')) {
            numStr += ch;
            idx++;
        } else {
            break;
        }
    }
    const value = Number(numStr);
    if (numStr === '' || !Number.isFinite(value)) return null;

    const fromUnit = canonicalUnit(leftPart.slice(idx));
    if (!fromUnit) return null;

    return { value, from: fromUnit, to: toUnit };
}

/**
 * Convert a value between two canonical units. Returns null for unknown units or
 * a cross-dimension request (e.g. kg → m).
 */
export function convertUnits(value: number, from: string, to: string): number | null {
    if (TEMPS.has(from) || TEMPS.has(to)) {
        // Temperature is affine; both sides must be temperatures.
        if (!TEMPS.has(from) || !TEMPS.has(to)) return null;
        let celsius: number;
        switch (from) {
            case 'c': celsius = value; break;
            case 'f': celsius = ((value - 32) * 5) / 9; break;
            case 'k': celsius = value - 273.15; break;
            default: return null;
        }
        switch (to) {
            case 'c': return celsius;
            case 'f': return (celsius * 9) / 5 + 32;
            case 'k': return celsius + 273.15;
            default: return null;
        }
    }

    const f = LINEAR[from];
    const t = LINEAR[to];
    if (!f || !t || f.dim !== t.dim) return null;
    return (value * f.toBase) / t.toBase;
}

/** Format a numeric result: integers stay integers, otherwise up to 4 decimals. */
export function formatUnitValue(v: number): string {
    if (Math.round(v) === v && Math.abs(v) < 1e12) return String(v);
    // Round half AWAY FROM ZERO (parity: unit-format-half-away-from-zero) — bare Math.round is
    // floor(x+0.5), half toward +∞, so -0.00025 rendered "-0.0002" here while the twins say "-0.0003".
    const scaled = v * 10000;
    return String((Math.sign(scaled) * Math.round(Math.abs(scaled))) / 10000); // up to 4 decimal places
}

/**
 * High-level entry point used by the chat tool handler: parse → convert → format.
 * Always returns a human-readable string (never throws) so a small local model's
 * garbage input degrades to a hint rather than an error.
 */
export function runUnitConversion(input: string): string {
    const req = parseConversion(input);
    if (!req) {
        return `Couldn't read a conversion from "${input}". Try "20 km to mi".`;
    }
    const result = convertUnits(req.value, req.from, req.to);
    if (result === null) {
        return `Can't convert ${req.from} to ${req.to} — they measure different things.`;
    }
    return `${formatUnitValue(req.value)} ${req.from} = ${formatUnitValue(result)} ${req.to}`;
}
