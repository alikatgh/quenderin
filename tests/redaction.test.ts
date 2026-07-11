import { describe, it, expect } from 'vitest';
import { redactSecrets } from '../src/services/capability/redaction.js';
import { InMemoryAuditLedger } from '../src/services/capability/capability.js';

/**
 * The audit ledger is a record you can open (`quenderin history`) — so it must never become the
 * place a leaked credential lives. Redaction masks recognizable secret shapes before anything is
 * stored, while leaving ordinary chore text untouched (high-precision, so the audit stays readable).
 */
describe('redactSecrets', () => {
    it('masks provider keys, bearer tokens, and password=… while keeping the label', () => {
        expect(redactSecrets('use key sk-ABCDEFGHIJKLMNOP1234')).toBe('use key sk-…redacted');
        expect(redactSecrets('token ghp_ABCDEFGHIJKLMNOP1234')).toContain('gh_…redacted');
        expect(redactSecrets('xoxb-1234567890-abcdEFGH')).toContain('xox-…redacted');
        expect(redactSecrets('Authorization: Bearer abcdefabcdef1234567890')).toContain('Bearer …redacted');
        expect(redactSecrets('password: hunter2longenough')).toBe('password: …redacted');
        expect(redactSecrets('api_key=SUPERSECRETVALUE')).toBe('api_key=…redacted');
    });

    it('leaves ordinary chore text completely alone (no over-redaction)', () => {
        for (const s of ['invoice.pdf to Finance', 'organize my downloads', 'call the dentist', 'File > Save As', 'water the plants']) {
            expect(redactSecrets(s)).toBe(s);
        }
    });

    it('is a no-op on empty input', () => {
        expect(redactSecrets('')).toBe('');
    });
});

describe('the ledger redacts on write', () => {
    it('an input carrying an API key is stored masked, never raw', () => {
        const ledger = new InMemoryAuditLedger();
        ledger.append({ timestampMs: 1, capability: 'mac.ui.type', tier: 3, input: 'type sk-ABCDEFGHIJKLMNOP1234 into the field', decision: 'allowed', outcome: 'Typed sk-ABCDEFGHIJKLMNOP1234.' });
        const row = ledger.entries()[0];
        expect(row.input).not.toContain('sk-ABCDEFGHIJKLMNOP1234');
        expect(row.input).toContain('…redacted');
        expect(row.outcome).not.toContain('sk-ABCDEFGHIJKLMNOP1234');   // outcome is masked too
    });

    it('a secret in the GOAL is redacted symmetrically with input/outcome (r-uc #8)', () => {
        const ledger = new InMemoryAuditLedger();
        ledger.append({ timestampMs: 1, capability: 'mac.ui.type', tier: 3, input: 'x', decision: 'allowed', goal: 'log in with sk-ABCDEFGHIJKLMNOP1234' });
        const row = ledger.entries()[0];
        expect(row.goal).not.toContain('sk-ABCDEFGHIJKLMNOP1234');
        expect(row.goal).toContain('…redacted');
    });
});
