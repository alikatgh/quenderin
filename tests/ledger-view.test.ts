import { describe, it, expect } from 'vitest';
import { formatHistory } from '../src/services/capability/ledgerView.js';
import type { AuditEntry } from '../src/services/capability/capability.js';

/**
 * `quenderin history` is the "review" pillar of the trust loop — the local, private audit log a
 * cloud agent can't offer. The renderer is pure (entries → string), so we pin ordering, the
 * decision glyphs, truncation, and the no-colour-by-default contract here, headless.
 */
const entry = (over: Partial<AuditEntry>): AuditEntry => ({
    timestampMs: 0, capability: 'fs.move', tier: 2, input: 'a.txt to docs', decision: 'allowed', ...over,
});

describe('formatHistory', () => {
    it('says so when the ledger is empty', () => {
        expect(formatHistory([])).toContain('No agent history yet');
    });

    it('renders newest-first with the capability, input, and outcome', () => {
        const out = formatHistory([
            entry({ timestampMs: 1_000, capability: 'fs.list', input: '', outcome: 'a.txt\nb.txt' }),
            entry({ timestampMs: 2_000, capability: 'fs.move', input: 'a.txt to docs', outcome: 'Moved "a.txt" into "docs/".' }),
        ]);
        const lines = out.split('\n');
        // 2_000 is newer → its capability line comes before the 1_000 one.
        expect(lines.findIndex(l => l.includes('fs.move'))).toBeLessThan(lines.findIndex(l => l.includes('fs.list')));
        expect(out).toContain('a.txt to docs');
        expect(out).toContain('→ Moved "a.txt" into "docs/".');
        expect(out).toContain('1970-01-01 00:00');   // deterministic UTC stamp
    });

    it('marks each decision with its own glyph and plain-English note', () => {
        const out = formatHistory([
            entry({ decision: 'allowed' }),
            entry({ capability: 'mac.mail.send', decision: 'blocked(pay)' }),
            entry({ capability: 'fs.trash', decision: 'declined' }),
            entry({ capability: 'fs.rename', decision: 'needsApproval' }),
        ]);
        expect(out).toContain('✓ fs.move');            // allowed
        expect(out).toMatch(/✗ mac\.mail\.send.*blocked by safety/);
        expect(out).toMatch(/✗ fs\.trash.*you declined/);
        expect(out).toMatch(/○ fs\.rename.*no approval/);
    });

    it('limits to the most recent N and notes how many are hidden', () => {
        const many = Array.from({ length: 5 }, (_, i) => entry({ timestampMs: i * 1000, capability: `cap${i}` }));
        const out = formatHistory(many, { limit: 2 });
        expect(out).toContain('cap4');                 // newest shown
        expect(out).toContain('cap3');
        expect(out).not.toContain('cap0');             // oldest hidden
        expect(out).toContain('…3 older entries');
        expect(out).toContain('5 logged');
    });

    it('is colourless by default and coloured only when asked', () => {
        const plain = formatHistory([entry({})]);
        expect(plain).not.toContain('\x1b[');          // no ANSI when piped/tested
        expect(formatHistory([entry({})], { color: true })).toContain('\x1b[');
    });

    it('counts an unverified run as "ran" in the tally', () => {
        const out = formatHistory([entry({ decision: 'allowed' }), entry({ decision: 'unverified' }), entry({ decision: 'declined' })]);
        expect(out).toContain('3 logged · 2 ran');
    });

    it('groups actions under a "Task:" header per goal (the structured per-task audit)', () => {
        const out = formatHistory([
            entry({ timestampMs: 3000, capability: 'fs.move', goal: 'organize downloads' }),
            entry({ timestampMs: 2000, capability: 'fs.list', goal: 'organize downloads' }),
            entry({ timestampMs: 1000, capability: 'mac.reminders.add', goal: 'plan my week' }),
        ]);
        expect(out).toContain('Task: organize downloads');
        expect(out).toContain('Task: plan my week');
        // The two "organize" actions share ONE header; the older task gets its own.
        expect(out.match(/Task:/g)).toHaveLength(2);
        // Header precedes its actions.
        const lines = out.split('\n');
        expect(lines.findIndex(l => l.includes('Task: organize'))).toBeLessThan(lines.findIndex(l => l.includes('fs.move')));
    });

    it('labels goal-less rows as "(no task recorded)" so old ledger entries still render', () => {
        const out = formatHistory([entry({ capability: 'fs.list' })]);   // no goal
        expect(out).toContain('(no task recorded)');
        expect(out).toContain('fs.list');
    });
});
