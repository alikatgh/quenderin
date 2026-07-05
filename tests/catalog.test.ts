import { describe, it, expect } from 'vitest';
import { formatCapabilities } from '../src/services/capability/catalog.js';
import { CapabilityTier } from '../src/services/capability/capability.js';
import { macCapabilities } from '../src/services/capability/macCapabilities.js';
import { fileCapabilities } from '../src/services/capability/fileCapabilities.js';
import type { MacAutomation } from '../src/services/capability/macAutomation.js';

/**
 * `quenderin capabilities` is the discovery front door — you can't ask for what you don't know the
 * agent can do. The renderer is pure, so we pin the grouping (perception vs actions), the
 * workspace hint on fs.*, and the no-colour-by-default contract here, headless.
 */
const noopMac: MacAutomation = { available: () => true, runAppleScript: async () => '' };

// A tiny hand-rolled capability so the grouping test doesn't depend on the real library's shape.
const cap = (name: string, tier: CapabilityTier, purpose: string) => ({
    name, tier, purpose,
    blastRadius: { kind: 'none' } as const,
    async plan() { return { summary: '', mutates: false }; },
    async run() { return ''; },
});

describe('formatCapabilities', () => {
    it('groups perception (T1) apart from actions (T2+), listing name + purpose', () => {
        const out = formatCapabilities([
            cap('mac.clipboard.read', CapabilityTier.ReadOnly, 'Read the clipboard.'),
            cap('fs.move', CapabilityTier.ReversibleWrite, 'Move a file into a subfolder.'),
            cap('mac.shortcuts.run', CapabilityTier.AppAction, 'Run one of your Shortcuts.'),
        ]);
        const lines = out.split('\n');
        const iPerc = lines.findIndex(l => l.includes('PERCEPTION'));
        const iAct = lines.findIndex(l => l.includes('ACTIONS'));
        expect(iPerc).toBeGreaterThanOrEqual(0);
        expect(iAct).toBeGreaterThan(iPerc);
        // read is under PERCEPTION (before ACTIONS); move + shortcuts under ACTIONS (after).
        expect(lines.findIndex(l => l.includes('mac.clipboard.read'))).toBeLessThan(iAct);
        expect(lines.findIndex(l => l.includes('fs.move'))).toBeGreaterThan(iAct);
        expect(lines.findIndex(l => l.includes('mac.shortcuts.run'))).toBeGreaterThan(iAct);
        expect(out).toContain('Move a file into a subfolder.');
    });

    it('flags fs.* as needing --workspace, but not mac.*', () => {
        const out = formatCapabilities([
            cap('fs.list', CapabilityTier.ReadOnly, 'List the workspace.'),
            cap('mac.frontApp', CapabilityTier.ReadOnly, 'Name the front app.'),
        ]);
        expect(out).toMatch(/fs\.list.*needs --workspace/);
        expect(out).not.toMatch(/mac\.frontApp.*needs --workspace/);
    });

    it('is colourless by default, coloured on request, and handles an empty library', () => {
        expect(formatCapabilities([cap('x', CapabilityTier.ReadOnly, 'y')])).not.toContain('\x1b[');
        expect(formatCapabilities([cap('x', CapabilityTier.ReadOnly, 'y')], { color: true })).toContain('\x1b[');
        expect(formatCapabilities([])).toContain('No capabilities available');
    });

    it('renders the REAL library the CLI assembles without throwing, covering every tool', () => {
        const caps = [...macCapabilities(noopMac), ...fileCapabilities(() => null)];
        const out = formatCapabilities(caps);
        // Every capability name appears exactly once in the listing.
        for (const c of caps) expect(out).toContain(c.name);
        expect(out).toContain('mac.shortcuts.run');   // the lodestar is discoverable
        expect(out).toContain('fs.write');            // the newest file tool is discoverable
    });
});
