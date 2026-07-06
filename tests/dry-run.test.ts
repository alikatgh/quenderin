import fs from 'fs';
import os from 'os';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { InMemoryConsentStore, InMemoryAuditLedger, RunSession } from '../src/services/capability/capability.js';
import { FsListCapability, FsMoveCapability } from '../src/services/capability/fileCapabilities.js';

/**
 * Dry run — "show me exactly what it would do, touching nothing." Reads run for real (so the plan is
 * grounded in the actual folder); mutating actions are previewed and skipped. An exact, side-effect-
 * free, LOCAL preview of machine changes — something a cloud agent can't offer. Even works with NO
 * approver, since nothing executes.
 */
let ws: string;
const workspace = () => ws;
beforeEach(() => { ws = fs.mkdtempSync(path.join(os.tmpdir(), 'qdry-')); });
afterEach(() => { fs.rmSync(ws, { recursive: true, force: true }); });

function dryRunner(session?: RunSession) {
    const consent = new InMemoryConsentStore();
    ['fs.list', 'fs.move'].forEach(id => consent.setGranted(id, true));
    // No approver on purpose — dry run must not need one.
    return new CapabilityRunner(consent, new InMemoryAuditLedger(), undefined, () => 0, session, 20, true);
}

describe('dry run — preview writes, execute reads, change nothing', () => {
    it('PREVIEWS a mutating action without doing it (and needs no approver)', async () => {
        fs.writeFileSync(path.join(ws, 'a.txt'), 'x');
        const session = new RunSession();
        const runner = dryRunner(session);

        const out = await runner.execute(new FsMoveCapability(workspace), 'a.txt to docs');
        expect(out).toContain('[dry run]');
        expect(out).toContain('Move "a.txt" into "docs/"');
        expect(fs.existsSync(path.join(ws, 'a.txt'))).toBe(true);          // NOT moved
        expect(fs.existsSync(path.join(ws, 'docs', 'a.txt'))).toBe(false);
        expect(session.undoableCount).toBe(0);                             // nothing to undo — nothing happened
    });

    it('still EXECUTES reads, so the preview is grounded in the real folder', async () => {
        fs.writeFileSync(path.join(ws, 'real.txt'), 'x');
        const out = await dryRunner().execute(new FsListCapability(workspace), '');
        expect(out).toContain('real.txt');   // the read actually ran
    });

    it('ledgers a previewed action as "dryRun", not "allowed"', async () => {
        fs.writeFileSync(path.join(ws, 'a.txt'), 'x');
        const ledger = new InMemoryAuditLedger();
        const consent = new InMemoryConsentStore(); consent.setGranted('fs.move', true);
        const runner = new CapabilityRunner(consent, ledger, undefined, () => 0, undefined, 20, true);
        await runner.execute(new FsMoveCapability(workspace), 'a.txt to docs');
        expect(ledger.entries().at(-1)?.decision).toBe('dryRun');
    });

    it('a plan with any write is shown whole and not run', async () => {
        fs.writeFileSync(path.join(ws, 'a.txt'), 'x');
        const runner = dryRunner();
        const out = await runner.executePlan([
            { capability: new FsMoveCapability(workspace), input: 'a.txt to docs' },
        ]);
        expect(out).toContain('[dry run]');
        expect(out).toContain('would run this plan');
        expect(fs.existsSync(path.join(ws, 'a.txt'))).toBe(true);   // untouched
    });

    it('a mixed read+write plan ledgers EVERY step as dryRun (a read never ran, so isn\'t "allowed")', async () => {
        fs.writeFileSync(path.join(ws, 'a.txt'), 'x');
        const ledger = new InMemoryAuditLedger();
        const consent = new InMemoryConsentStore(); ['fs.list', 'fs.move'].forEach(id => consent.setGranted(id, true));
        const runner = new CapabilityRunner(consent, ledger, undefined, () => 0, undefined, 20, true);
        await runner.executePlan([
            { capability: new FsListCapability(workspace), input: '' },              // a read
            { capability: new FsMoveCapability(workspace), input: 'a.txt to docs' },  // a write
        ]);
        expect(ledger.entries().map(e => e.decision)).toEqual(['dryRun', 'dryRun']);   // NOT ['allowed','dryRun']
        expect(fs.existsSync(path.join(ws, 'a.txt'))).toBe(true);                       // read never ran either
    });

    it('CONTROL: without dry run the same move actually happens', async () => {
        fs.writeFileSync(path.join(ws, 'a.txt'), 'x');
        const consent = new InMemoryConsentStore(); consent.setGranted('fs.move', true);
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async () => true, () => 0);   // dryRun defaults false
        await runner.execute(new FsMoveCapability(workspace), 'a.txt to docs');
        expect(fs.existsSync(path.join(ws, 'docs', 'a.txt'))).toBe(true);   // really moved
    });
});
