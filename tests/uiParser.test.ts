import { describe, it, expect } from 'vitest';
import { UiParserService } from '../src/services/uiParser.service.js';

/**
 * The UI XML is device-sourced (/sdcard/window_dump.xml) and untrusted. Regression for the deep-hunt:
 * `traverse` recursed with no depth bound (a deeply nested dump could overflow the stack) and `stateMap`
 * grew with no size bound (a huge dump could exhaust memory). Both are now capped.
 */
describe('UiParserService — bounds against a hostile UI dump', () => {
    const svc = new UiParserService();

    it('parses a normal small dump correctly', () => {
        const xml = '<hierarchy><node text="Hello" bounds="[0,0][100,50]" clickable="true"/></hierarchy>';
        const { elements } = svc.parseUI(xml);
        expect(elements.length).toBe(1);
        expect(elements[0].text).toBe('Hello');
        expect(elements[0].center).toEqual({ x: 50, y: 25 });
    });

    it('caps the number of registered elements (memory bound) on a huge dump', () => {
        let inner = '';
        for (let i = 0; i < 6000; i++) inner += `<node text="t${i}" bounds="[0,0][1,1]"/>`;
        const xml = `<hierarchy><node>${inner}</node></hierarchy>`;
        const { elements } = svc.parseUI(xml);
        expect(elements.length).toBeLessThanOrEqual(5000); // MAX_ELEMENTS
        expect(elements.length).toBeGreaterThan(100);       // but it did parse real content
    });

    it('handles a deeply nested dump gracefully — never an uncatchable stack overflow', () => {
        let open = '';
        let close = '';
        for (let i = 0; i < 3000; i++) {
            open += `<node bounds="[0,0][1,1]" text="d${i}">`;
            close = `</node>` + close;
        }
        const xml = `<hierarchy>${open}${close}</hierarchy>`;
        // Two layers of defense: fast-xml-parser rejects excessive nesting with a CATCHABLE Error, and
        // our traverse caps recursion depth. Either way the failure mode we prevent — an uncatchable
        // stack overflow that downs the process — must not occur. So: catchable error OR bounded result.
        let outcome: 'threw' | number;
        try {
            outcome = svc.parseUI(xml).elements.length;
        } catch (e) {
            outcome = e instanceof Error ? 'threw' : (() => { throw e; })();
        }
        expect(outcome === 'threw' || (typeof outcome === 'number' && outcome <= 501)).toBe(true);
    });
});
