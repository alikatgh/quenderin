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

/**
 * The LLM representation must be token-LEAN (no serialized nulls, no signal-free structural nodes,
 * capped per-node text) and context-BUDGETED (interactable elements survive a clamp, decorative
 * labels are dropped first, original ids + screen order preserved). A busy screen used to out-size
 * the whole context of a small-RAM machine by itself.
 */
describe('UiParserService.buildLLMPromptRepresentation — lean + budgeted', () => {
    const svc = new UiParserService();

    function stateMapFor(xml: string) {
        return svc.buildStateMap(svc.parseRawTree(xml));
    }

    it('emits only signal-bearing fields — never null placeholders', () => {
        const xml = '<hierarchy><node text="Save" bounds="[0,0][10,10]" clickable="true"/><node content-desc="Back" bounds="[0,0][5,5]"/></hierarchy>';
        const out = svc.buildLLMPromptRepresentation(stateMapFor(xml));
        expect(out).not.toContain('null');
        const nodes = JSON.parse(out);
        expect(nodes[0]).toEqual({ id: 0, text: 'Save', interactable: true });
        expect(nodes[1]).toEqual({ id: 1, desc: 'Back' });
    });

    it('drops nodes with no text, no description, and no interactivity (pure structure)', () => {
        const xml = '<hierarchy><node bounds="[0,0][10,10]"/><node text="Real" bounds="[0,0][10,10]"/></hierarchy>';
        const nodes = JSON.parse(svc.buildLLMPromptRepresentation(stateMapFor(xml)));
        expect(nodes.length).toBe(1);
        expect(nodes[0].text).toBe('Real');
    });

    it('caps per-node text at 200 chars (article bodies must not flood the prompt)', () => {
        const long = 'x'.repeat(5000);
        const xml = `<hierarchy><node text="${long}" bounds="[0,0][10,10]"/></hierarchy>`;
        const nodes = JSON.parse(svc.buildLLMPromptRepresentation(stateMapFor(xml)));
        expect(nodes[0].text.length).toBe(200);
    });

    it('under a tight budget, keeps interactable elements and sheds labels — original ids intact', () => {
        let inner = '';
        for (let i = 0; i < 40; i++) {
            inner += `<node text="label with a reasonably long decorative caption ${i}" bounds="[0,0][1,1]"/>`;
            inner += `<node text="btn${i}" bounds="[0,0][1,1]" clickable="true"/>`;
        }
        const map = stateMapFor(`<hierarchy><node>${inner}</node></hierarchy>`);
        const out = svc.buildLLMPromptRepresentation(map, 2500);
        expect(out.length).toBeLessThanOrEqual(2500);
        const nodes = JSON.parse(out) as Array<{ id: number; text?: string; interactable?: boolean }>;
        const targets = nodes.filter(n => n.interactable);
        expect(targets.length).toBeGreaterThan(30);            // targets survived the clamp
        expect(targets.length).toBeGreaterThan(nodes.length - targets.length); // labels shed first
        // Ids are the ORIGINAL state-map ids (they must keep resolving for the executor)…
        for (const n of nodes) expect(map.has(n.id)).toBe(true);
        // …and output is in ascending id order (original screen order).
        const ids = nodes.map(n => n.id);
        expect([...ids].sort((a, b) => a - b)).toEqual(ids);
    });

    it('fits generous content without dropping anything when under budget', () => {
        const xml = '<hierarchy><node text="A" bounds="[0,0][1,1]"/><node text="B" bounds="[0,0][1,1]" clickable="true"/></hierarchy>';
        const nodes = JSON.parse(svc.buildLLMPromptRepresentation(stateMapFor(xml), 14000));
        expect(nodes.length).toBe(2);
        expect(nodes.map((n: { id: number }) => n.id)).toEqual([0, 1]);
    });
});
