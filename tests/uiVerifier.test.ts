import { describe, it, expect, beforeEach } from 'vitest';
import { UiVerifier } from '../src/services/agent/uiVerifier.js';
import type { IDeviceProvider, UIElement } from '../src/types/index.js';
import type { UiParserService } from '../src/services/uiParser.service.js';
import type { OcrService } from '../src/services/ocr.service.js';

/**
 * Focused unit tests for UiVerifier.verifyAction.
 *
 * verifyAction is a pure-ish comparison over (action, preStateElements, postStateElements):
 * it inspects only its arguments and never reaches into the injected deviceProvider /
 * uiParserService / ocrService. So we construct the verifier with inert stubs cast to the
 * required interfaces — no real ADB device, no model load, no network. (waitForIdle / hashUiState
 * pull in real device + OCR + fs side effects and are out of scope here; verifyAction is the
 * cleanly unit-testable surface.)
 */

// Minimal UIElement factory — only the fields verifyAction actually reads (id, className, text,
// contentDesc) need to be meaningful; the rest are filled with valid-but-irrelevant defaults so
// the fixture satisfies the UIElement type.
function makeElement(overrides: Partial<UIElement> & { id: number }): UIElement {
    return {
        text: '',
        contentDesc: '',
        className: 'android.widget.View',
        resourceId: '',
        clickable: true,
        scrollable: false,
        focusable: true,
        enabled: true,
        visible: true,
        bounds: '[0,0][100,100]',
        center: { x: 50, y: 50 },
        rect: { x: 0, y: 0, width: 100, height: 100 },
        ...overrides,
    };
}

describe('UiVerifier.verifyAction', () => {
    let verifier: UiVerifier;

    beforeEach(() => {
        // Inert stubs: verifyAction never calls any of these, so empty objects cast to the
        // interfaces are sufficient and keep the test fully deterministic / offline.
        const deviceProvider = {} as unknown as IDeviceProvider;
        const uiParserService = {} as unknown as UiParserService;
        const ocrService = {} as unknown as OcrService;
        verifier = new UiVerifier(deviceProvider, uiParserService, ocrService);
    });

    it('flags a non-numeric target id with an "[Warning] ... invalid ..." string', async () => {
        const result = await verifier.verifyAction(
            { action: 'click', target_id: 'submit' },
            [],
            [],
        );
        expect(result).toContain('[Warning]');
        expect(result).toContain('invalid');
        // The malformed raw id is echoed back (JSON-stringified) so the operator can see it.
        expect(result).toContain('"submit"');
    });

    it('flags a non-numeric target id as invalid (never a misleading "ID NaN not found")', async () => {
        const result = await verifier.verifyAction(
            // "btn" -> parseInt -> NaN; the guard must report it as invalid, never as
            // "ID NaN not found in the pre-action state".
            { action: 'input', target_id: 'btn' },
            [makeElement({ id: 0, text: 'A' })],
            [makeElement({ id: 0, text: 'A' })],
        );
        expect(result).toContain('[Warning]');
        expect(result).toContain('invalid');
        expect(result).not.toContain('not found in the pre-action state');
        expect(result).not.toContain('NaN');
    });

    it('returns a not-found warning when the target id is absent from the pre-state', async () => {
        const result = await verifier.verifyAction(
            { action: 'click', target_id: 7 },
            // pre-state has ids 0 and 1 — nothing with id 7.
            [makeElement({ id: 0, text: 'Home' }), makeElement({ id: 1, text: 'Settings' })],
            [makeElement({ id: 0, text: 'Home' })],
        );
        expect(result).toContain('[Warning]');
        expect(result).toContain('ID 7');
        expect(result).toContain('not found in the pre-action state');
    });

    it('reports [Failed] when the targeted node is present in pre AND still present in post (unchanged)', async () => {
        const target = makeElement({
            id: 2,
            text: 'Submit',
            className: 'android.widget.Button',
            contentDesc: 'submit-btn',
        });
        // Post state still contains a node matching className + text + contentDesc => unchanged.
        const stillThere = makeElement({
            id: 99, // id may shift on redraw — matching is by className/text/contentDesc, not id.
            text: 'Submit',
            className: 'android.widget.Button',
            contentDesc: 'submit-btn',
        });
        const result = await verifier.verifyAction(
            { action: 'click', target_id: 2 },
            [target],
            [stillThere],
        );
        expect(result).toContain('[Failed]');
        expect(result).toContain('still visible');
        // Describes the element by its text.
        expect(result).toContain('Submit');
    });

    it('reports [Success] when the targeted node disappeared from the post-state (UI changed)', async () => {
        const target = makeElement({
            id: 3,
            text: 'Dialog OK',
            className: 'android.widget.Button',
            contentDesc: 'ok',
        });
        // Post state has a different node — the target is gone.
        const replacement = makeElement({
            id: 0,
            text: 'Home screen',
            className: 'android.widget.TextView',
            contentDesc: 'home',
        });
        const result = await verifier.verifyAction(
            { action: 'click', target_id: 3 },
            [target],
            [replacement],
        );
        expect(result).toContain('[Success]');
        expect(result).toContain('UI changed');
        expect(result).toContain('no longer in the same state');
    });

    it('treats target id 0 as a real target (not "no target"): id 0 present in both => [Failed]', async () => {
        // Regression guard: `!targetIdRaw` would wrongly skip id 0; the code tests undefined/null
        // explicitly so the root/first element is verified.
        const root = makeElement({ id: 0, text: 'Root', className: 'android.widget.FrameLayout' });
        const result = await verifier.verifyAction(
            { action: 'click', target_id: 0 },
            [root],
            [makeElement({ id: 0, text: 'Root', className: 'android.widget.FrameLayout' })],
        );
        expect(result).toContain('[Failed]');
        expect(result).toContain('still visible');
    });

    it('falls back to actionObj.id when target_id is undefined', async () => {
        // targetIdRaw = actionObj.target_id ?? actionObj.id — verify the `id` fallback path.
        const node = makeElement({ id: 5, text: 'Tab', className: 'android.widget.Button' });
        const result = await verifier.verifyAction(
            { action: 'input', id: 5 }, // no target_id
            [node],
            [], // gone from post-state => success
        );
        expect(result).toContain('[Success]');
        expect(result).toContain('no longer in the same state');
    });

    it('skips target verification for non-targeted action types and reports plain [Success]', async () => {
        const result = await verifier.verifyAction(
            { action: 'scroll', target_id: 2 }, // not click/input => not verified against state
            [makeElement({ id: 2, text: 'List' })],
            [makeElement({ id: 2, text: 'List' })],
        );
        expect(result).toBe('[Success] Executed scroll.');
    });

    it('returns a generic [Success] when target id is missing entirely', async () => {
        const result = await verifier.verifyAction(
            { action: 'click' }, // no target_id, no id
            [makeElement({ id: 0, text: 'A' })],
            [],
        );
        expect(result).toBe('[Success] Executed click.');
    });
});
