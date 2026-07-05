import { describe, it, expect } from 'vitest';
import { RunSession, InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { ReminderAddCapability, NoteCreateCapability, OpenAppCapability } from '../src/services/capability/macCapabilities.js';
import type { MacAutomation } from '../src/services/capability/macAutomation.js';

class FakeMac implements MacAutomation {
    scripts: string[] = [];
    available(): boolean { return true; }
    async runAppleScript(script: string): Promise<string> { this.scripts.push(script); return 'ok'; }
}

function grant(...ids: string[]) {
    const c = new InMemoryConsentStore();
    ids.forEach(id => c.setGranted(id, true));
    return c;
}

/**
 * "Undo this whole task" — the pair to the kill switch. An agent that created a reminder and a
 * note during a run can have BOTH reversed with one click, newest-first. A cloud agent can't
 * offer transactional undo of your local changes; this local one can.
 */
describe('RunSession — undo the whole task', () => {
    it('records undoable mutating actions and reverses them LIFO', async () => {
        const mac = new FakeMac();
        const session = new RunSession();
        const runner = new CapabilityRunner(
            grant('mac.reminders.add', 'mac.notes.create'),
            new InMemoryAuditLedger(),
            async () => true,
            () => 0,
            session,
        );
        const reminder = new ReminderAddCapability(mac);
        const note = new NoteCreateCapability(mac);

        await runner.execute(reminder, 'call the dentist');
        await runner.execute(note, 'Trip plan\nflights, hotel');
        expect(session.undoableCount).toBe(2);

        const createScripts = mac.scripts.length;
        const undoSummary = await session.undoAll();

        // Reversed newest-first: the NOTE undo (delete) runs before the REMINDER undo.
        expect(undoSummary).toBe('Removed the note "Trip plan".\nRemoved the reminder "call the dentist".');
        const undoScripts = mac.scripts.slice(createScripts);
        expect(undoScripts[0]).toContain('delete (every note whose name is "Trip plan")');
        expect(undoScripts[1]).toContain('delete (every reminder whose name is "call the dentist")');
        expect(session.undoableCount).toBe(0);   // drained
    });

    it('only records actions whose capability CAN undo — a tap/open with no undo is skipped', async () => {
        const mac = new FakeMac();
        const session = new RunSession();
        const runner = new CapabilityRunner(grant('mac.app.open', 'mac.reminders.add'), new InMemoryAuditLedger(), async () => true, () => 0, session);
        await runner.execute(new OpenAppCapability(mac), 'Safari');   // no undo() → not recorded
        await runner.execute(new ReminderAddCapability(mac), 'call mom');
        expect(session.undoableCount).toBe(1);
        expect(await session.undoAll()).toContain('Removed the reminder "call mom"');
    });

    it('undo is BEST-EFFORT: one failed reversal is reported, the rest still roll back', async () => {
        const failing: MacAutomation = {
            available: () => true,
            runAppleScript: async (s: string) => { if (s.includes('delete') && s.includes('Trip')) throw new Error('locked'); return 'ok'; },
        };
        const session = new RunSession();
        const runner = new CapabilityRunner(grant('mac.reminders.add', 'mac.notes.create'), new InMemoryAuditLedger(), async () => true, () => 0, session);
        await runner.execute(new ReminderAddCapability(failing), 'call the dentist');
        await runner.execute(new NoteCreateCapability(failing), 'Trip plan');
        const out = await session.undoAll();
        expect(out).toContain('Couldn\'t');            // the note reversal failed
        expect(out).toContain('Removed the reminder "call the dentist"');   // …but the reminder still rolled back
    });

    it('an empty session says so', async () => {
        expect(await new RunSession().undoAll()).toBe('Nothing to undo from this task.');
    });
});
