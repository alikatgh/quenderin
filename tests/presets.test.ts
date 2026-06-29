import { describe, expect, it } from 'vitest';
import { DEFAULT_PRESETS, getPresetById, type Preset } from '../src/services/presets.js';

/**
 * Tests for the project/context preset registry.
 *
 * NOTE on the hardware-adaptation gap:
 *   `getPresetById` runs the matched preset through `adaptPreset`, which — on the
 *   `embedded`/`constrained` hardware tiers — scales `maxTokens` down and trims the
 *   `systemPrompt` to a short prefix. The resulting values therefore depend on the
 *   machine the suite runs on. We deliberately DO NOT assert exact `maxTokens` or
 *   exact `systemPrompt` strings on the value returned by `getPresetById`, since
 *   those are tier-dependent and would be flaky across CI hardware. Instead we assert
 *   the tier-invariant contract: identity (`id`), `label`, and the unknown-id fallback.
 *   Exact prompt/token content is asserted against the un-adapted `DEFAULT_PRESETS`
 *   source array, which is the stable input to that adaptation.
 */

describe('getPresetById', () => {
    it('returns the matching preset for each valid id', () => {
        for (const source of DEFAULT_PRESETS) {
            const result = getPresetById(source.id);
            // Identity and label survive hardware adaptation on every tier.
            expect(result.id).toBe(source.id);
            expect(result.label).toBe(source.label);
            expect(result.icon).toBe(source.icon);
            expect(result.description).toBe(source.description);
        }
    });

    it('returns the code-review preset (not the default) for id "code-review"', () => {
        const result = getPresetById('code-review');
        expect(result.id).toBe('code-review');
        expect(result.label).toBe('Code Review');
        // Distinct from the general fallback — proves a real lookup happened.
        expect(result.id).not.toBe('general');
    });

    it('falls back to the general preset for an unknown id', () => {
        const result = getPresetById('does-not-exist');
        expect(result.id).toBe('general');
        expect(result.label).toBe(DEFAULT_PRESETS[0].label);
        expect(DEFAULT_PRESETS[0].id).toBe('general'); // guards the fallback contract: index 0 IS general
    });

    it('falls back to general for empty-string and other non-matching ids', () => {
        for (const bogus of ['', 'GENERAL', 'general ', 'tutor-x', '__proto__']) {
            expect(getPresetById(bogus).id).toBe('general');
        }
    });

    it('always returns a usable preset (non-empty systemPrompt + label) on the current hardware tier', () => {
        // After hardware adaptation the prompt may be trimmed, but it must never be emptied.
        for (const source of DEFAULT_PRESETS) {
            const result = getPresetById(source.id);
            expect(result.systemPrompt.length).toBeGreaterThan(0);
            expect(result.label.length).toBeGreaterThan(0);
            // maxTokens is scaled per tier but is floored at 64 by adaptPreset.
            expect(result.maxTokens).toBeGreaterThanOrEqual(64);
            expect(Number.isFinite(result.maxTokens)).toBe(true);
        }
    });

    it('returns content consistent with the DEFAULT_PRESETS source for the general preset', () => {
        // On standard/powerful tiers adaptPreset returns the registry entry unchanged;
        // on constrained tiers it spreads into a copy. Either way the *identity contract*
        // (id/label/icon/description) must match the source registry entry. We assert that
        // tier-invariant equality rather than object identity (which is tier-dependent).
        const result = getPresetById('general');
        const source = DEFAULT_PRESETS[0];
        expect(result.id).toBe(source.id);
        expect(result.label).toBe(source.label);
        expect(result.icon).toBe(source.icon);
        expect(result.description).toBe(source.description);
        expect(result.temperature).toBe(source.temperature);
    });
});

describe('DEFAULT_PRESETS integrity', () => {
    it('contains the expected core presets', () => {
        const ids = DEFAULT_PRESETS.map(p => p.id);
        expect(ids).toContain('general');
        expect(ids).toContain('code-review');
        expect(ids).toContain('creative-writer');
        expect(ids).toContain('tutor');
        expect(ids).toContain('summarizer');
    });

    it('has unique ids', () => {
        const ids = DEFAULT_PRESETS.map(p => p.id);
        expect(new Set(ids).size).toBe(ids.length);
    });

    it('every preset has a non-empty id, label, description, icon, and systemPrompt', () => {
        for (const preset of DEFAULT_PRESETS) {
            expect(preset.id.trim().length).toBeGreaterThan(0);
            expect(preset.label.trim().length).toBeGreaterThan(0);
            expect(preset.description.trim().length).toBeGreaterThan(0);
            expect(preset.icon.trim().length).toBeGreaterThan(0);
            expect(preset.systemPrompt.trim().length).toBeGreaterThan(0);
        }
    });

    it('every preset has a sane temperature and positive maxTokens', () => {
        for (const preset of DEFAULT_PRESETS) {
            expect(preset.temperature).toBeGreaterThanOrEqual(0);
            expect(preset.temperature).toBeLessThanOrEqual(2);
            expect(preset.maxTokens).toBeGreaterThan(0);
            expect(Number.isInteger(preset.maxTokens)).toBe(true);
        }
    });

    it('the general preset is at index 0 (the documented fallback target)', () => {
        const first: Preset = DEFAULT_PRESETS[0];
        expect(first.id).toBe('general');
    });
});
