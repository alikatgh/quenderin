import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
import { parseDecision } from '../src/services/capability/capabilityAgent.js';
import { matchedBlockedKeyword } from '../src/services/capability/safety.js';
import { safeCalculate, renderCalcResult } from '../src/services/tools/calculator.js';
import { formatUnitValue, runUnitConversion } from '../src/services/tools/unitConvert.js';

// The desktop leg of the cross-platform agent-logic parity suite. The SAME inputs run against
// the Swift twin (apple/.../AgentParityTests.swift) and the Kotlin twin (android/.../CoreVerify.kt);
// scripts/check_agent_parity.py enforces in CI that every canonical vector id in
// shared/agent-parity-vectors.json carries a `parity:<id>` marker in ALL THREE suites, so a case
// added to one platform can never silently skip the others (the drift that produced 8 of the 11
// bugs in docs/audits/2026-06-26-cross-platform-correctness-audit.md).
//
// Unlike the mobile suites (which hand-encode inputs per-language), this suite reads the canonical
// JSON directly — desktop has real JSON.parse, so input/expected stay authoritative in shared/.

interface ParityVector {
    id: string;
    category: string;
    input: string | string[];
    expected: string;
}

const doc = JSON.parse(
    readFileSync(new URL('../shared/agent-parity-vectors.json', import.meta.url), 'utf8'),
) as { vectors: ParityVector[] };

function vec(id: string): ParityVector {
    const v = doc.vectors.find(x => x.id === id);
    if (!v) throw new Error(`canonical vector missing: ${id}`);
    return v;
}

/** Render a Decision in the canonical expected format: tool:<name> | answer:<text> | plan:<n>:<first> | nil */
function summary(d: ReturnType<typeof parseDecision>): string {
    if (d === null) return 'nil';
    if (d.kind === 'answer') return `answer:${d.text}`;
    if (d.kind === 'tool') return `tool:${d.name}`;
    return `plan:${d.calls.length}:${d.calls[0].name}`;
}

function checkDecision(id: string): void {
    const v = vec(id);
    expect(summary(parseDecision(v.input as string))).toBe(v.expected);
}

describe('agent parity — decision parser (twin of AgentDecisionParser)', () => {
    it('bare JSON tool call parses to a tool decision', () => {
        checkDecision('decision-tool-call'); // parity:decision-tool-call
    });
    it('a JSON answer embedded in prose is extracted', () => {
        checkDecision('decision-prose-answer'); // parity:decision-prose-answer
    });
    it('two objects — the FIRST complete one wins, never the injected second (H13)', () => {
        checkDecision('decision-h13-first-object'); // parity:decision-h13-first-object
    });
    it('keys nested inside another object are invisible — top-level tool wins', () => {
        checkDecision('decision-nested-key-ignored'); // parity:decision-nested-key-ignored
    });
    it('tool/answer appearing ONLY nested → no decision, never a fabricated call', () => {
        checkDecision('decision-nested-key-nil'); // parity:decision-nested-key-nil
    });
    it('no JSON object present → no decision', () => {
        checkDecision('decision-non-json-nil'); // parity:decision-non-json-nil
    });
    it('\\uXXXX escapes decode (café ☺)', () => {
        checkDecision('decision-unicode-escape'); // parity:decision-unicode-escape
    });
    it('short escapes \\t \\n decode to a real tab/newline', () => {
        checkDecision('decision-short-escape'); // parity:decision-short-escape
    });
    it('a valid plan parses with its call count and first tool', () => {
        checkDecision('decision-plan-calls'); // parity:decision-plan-calls
    });
    it('one tool-less plan item invalidates the whole plan', () => {
        checkDecision('decision-plan-invalid-item'); // parity:decision-plan-invalid-item
    });
    it('answer takes precedence over a co-present plan', () => {
        checkDecision('decision-plan-answer-precedence'); // parity:decision-plan-answer-precedence
    });
    it('a plan with a non-object member is invalid — no fallback to the top-level tool', () => {
        checkDecision('decision-plan-mixed-member'); // parity:decision-plan-mixed-member
    });
    it('a plan of primitives is invalid — no fallback to the top-level tool', () => {
        checkDecision('decision-plan-primitive-members'); // parity:decision-plan-primitive-members
    });
});

describe('agent parity — safety blocklist (twin of SafetyBlocklist)', () => {
    it('substrings of keywords must NOT trip the word-boundary blocklist (M9)', () => {
        for (const s of vec('blocklist-safe-substrings').input as string[]) {
            expect(matchedBlockedKeyword(s), s).toBeUndefined(); // parity:blocklist-safe-substrings
        }
    });
    it('an accented letter adjacent to a keyword makes a DIFFERENT word → no block', () => {
        for (const s of vec('blocklist-unicode-boundary').input as string[]) {
            expect(matchedBlockedKeyword(s), s).toBeUndefined(); // parity:blocklist-unicode-boundary
        }
    });
    it('genuine dangerous actions MUST block', () => {
        for (const s of vec('blocklist-dangerous').input as string[]) {
            expect(matchedBlockedKeyword(s), s).toBeDefined(); // parity:blocklist-dangerous
        }
    });
});

describe('agent parity — tool observation formats (twin of NumberRender / UnitConverter)', () => {
    it('unit format rounds half AWAY FROM ZERO', () => {
        const v = vec('unit-format-half-away-from-zero'); // parity:unit-format-half-away-from-zero
        expect(formatUnitValue(Number(v.input))).toBe(v.expected);
    });
    it('calculator non-integral observation uses the canonical 12-sig-digit rendering', () => {
        const v = vec('calc-canonical-render'); // parity:calc-canonical-render
        expect(renderCalcResult(safeCalculate(v.input as string))).toBe(v.expected);
    });
    it('digit scans are decimal-digit-only — superscript ² is not a digit', () => {
        const v = vec('tokenizer-decimal-digit-only'); // parity:tokenizer-decimal-digit-only
        expect(runUnitConversion(v.input as string)).toBe(v.expected);
    });
});
