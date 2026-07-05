import { describe, it, expect } from 'vitest';
import { MacAutomation, escapeAppleScriptString } from '../src/services/capability/macAutomation.js';
import {
    CalendarTodayCapability, ReminderAddCapability,
    FrontAppCapability, ClipboardReadCapability, OpenAppCapability, NoteCreateCapability,
} from '../src/services/capability/macCapabilities.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';

/** A fake macOS automation: returns canned stdout and records the exact scripts it was asked to run. */
class FakeMac implements MacAutomation {
    scripts: string[] = [];
    constructor(private readonly stdout: string = 'ok', private readonly avail = true, private readonly fail?: string) { }
    available(): boolean { return this.avail; }
    async runAppleScript(script: string): Promise<string> {
        this.scripts.push(script);
        if (this.fail) throw Object.assign(new Error(this.fail), { code: 'MAC_ERROR' });
        return this.stdout;
    }
}

/** A fake that fails the FIRST script and succeeds after — for the Notes iCloud→default fallback. */
class FakeMacFailOnce implements MacAutomation {
    scripts: string[] = [];
    private failed = false;
    available(): boolean { return true; }
    async runAppleScript(script: string): Promise<string> {
        this.scripts.push(script);
        if (!this.failed) { this.failed = true; throw Object.assign(new Error('no such folder'), { code: 'MAC_ERROR' }); }
        return 'ok';
    }
}

describe('escapeAppleScriptString — closes the AppleScript-injection layer', () => {
    it('escapes quotes and backslashes and neutralizes control chars', () => {
        expect(escapeAppleScriptString('buy milk')).toBe('buy milk');
        // A value trying to break out of the string literal to run a second statement — the
        // newline collapses to a space (adjacent to the original space → two), quotes escape.
        expect(escapeAppleScriptString('x" \nbeep "y')).toBe('x\\"  beep \\"y');
        expect(escapeAppleScriptString('back\\slash')).toBe('back\\\\slash');
    });
});

describe('mac.calendar.today (T1, read-only)', () => {
    it('reads events without approval and surfaces an empty-day message', async () => {
        const mac = new FakeMac('Standup @ 9:00:00 AM\n');
        const consent = new InMemoryConsentStore(); consent.setGranted('mac.calendar.today', true);
        const runner = new CapabilityRunner(consent);   // no approver — reads need none
        const out = await runner.execute(new CalendarTodayCapability(mac), '');
        expect(out).toContain('Standup @ 9:00:00 AM');
        expect(mac.scripts[0]).toContain('tell application "Calendar"');

        const empty = new FakeMac('   ');
        expect(await new CalendarTodayCapability(empty).run()).toBe('No events on your calendar today.');
    });
});

describe('mac.reminders.add (T2 — approved, injection-safe)', () => {
    const grant = () => { const c = new InMemoryConsentStore(); c.setGranted('mac.reminders.add', true); return c; };

    it('adds a reminder only after approval, with the title safely escaped into the template', async () => {
        const mac = new FakeMac('ok');
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(new ReminderAddCapability(mac), 'call the dentist');
        expect(out).toBe('Added a reminder: "call the dentist".');
        expect(mac.scripts[0]).toContain('make new reminder with properties {name:"call the dentist"}');
    });

    it('FAILS CLOSED without an approver — no script runs', async () => {
        const mac = new FakeMac('ok');
        const ledger = new InMemoryAuditLedger();
        const out = await new CapabilityRunner(grant(), ledger).execute(new ReminderAddCapability(mac), 'x');
        expect(out).toContain('needs your per-run approval');
        expect(mac.scripts).toHaveLength(0);
        expect(ledger.entries().at(-1)?.decision).toBe('needsApproval');
    });

    it('a malicious title cannot break out of the AppleScript string literal', async () => {
        // Call run() directly to isolate the ESCAPING (a payload with a blocklist word like
        // "delete" would be caught earlier by the runner — that's tested separately; this proves
        // the escaper stops a break-out that the blocklist wouldn't catch).
        const mac = new FakeMac('ok');
        await new ReminderAddCapability(mac).run('ok"} beep 3 --');
        const script = mac.scripts[0];
        expect(script).toContain('\\"');                 // the embedded quote is escaped
        expect(script).not.toMatch(/name:"ok"\}/);       // the raw break-out sequence never appears unescaped
        expect(script).toContain('name:"ok\\"} beep 3 --"');  // it stays one string literal
    });

    it('is refused by the blocklist when the reminder text names a blocked action', async () => {
        const mac = new FakeMac('ok');
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(new ReminderAddCapability(mac), 'wire the deposit and send money');
        expect(out).toContain('blocked action');
        expect(mac.scripts).toHaveLength(0);
    });

    it('says macOS-only off darwin, and explains the Automation-permission prompt on failure', async () => {
        expect(await new ReminderAddCapability(new FakeMac('ok', false)).run('x')).toBe('This runs on macOS only.');
        const denied = new FakeMac('ok', true, 'Not allowed to send Apple events');
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(new ReminderAddCapability(denied), 'x');
        expect(out).toContain('System Settings');
    });
});

describe('perception capabilities (T1 — no approval)', () => {
    it('mac.frontApp names the active app', async () => {
        const mac = new FakeMac('Safari');
        const consent = new InMemoryConsentStore(); consent.setGranted('mac.frontApp', true);
        const out = await new CapabilityRunner(consent).execute(new FrontAppCapability(mac), '');
        expect(out).toBe('The frontmost app is Safari.');
        expect(mac.scripts[0]).toContain('frontmost is true');
    });

    it('mac.clipboard.read returns the clipboard text and truncates huge content', async () => {
        expect(await new ClipboardReadCapability(new FakeMac('copied text')).run()).toBe('copied text');
        expect(await new ClipboardReadCapability(new FakeMac('')).run()).toContain('clipboard is empty');
        const big = new ClipboardReadCapability(new FakeMac('x'.repeat(5000)), 100);
        expect(await big.run()).toContain('[…clipboard truncated]');
    });
});

describe('mac.app.open (T2 — approved)', () => {
    const grant = () => { const c = new InMemoryConsentStore(); c.setGranted('mac.app.open', true); return c; };

    it('opens an app after approval', async () => {
        const mac = new FakeMac('');
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new OpenAppCapability(mac), 'Safari')).toBe('Opened "Safari".');
        expect(mac.scripts[0]).toBe('tell application "Safari" to activate');
    });

    it('reports a missing app cleanly and fails closed without approval', async () => {
        const missing = new FakeMac('ok', true, "Can’t get application \"Nope\"");
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new OpenAppCapability(missing), 'Nope')).toContain('Couldn\'t find an app');
        const mac = new FakeMac('');
        expect(await new CapabilityRunner(grant()).execute(new OpenAppCapability(mac), 'Safari')).toContain('per-run approval');
        expect(mac.scripts).toHaveLength(0);
    });
});

describe('mac.notes.create (T2 — approved, iCloud→default fallback)', () => {
    const grant = () => { const c = new InMemoryConsentStore(); c.setGranted('mac.notes.create', true); return c; };

    it('creates a note after approval, first line as the title', async () => {
        const mac = new FakeMac('ok');
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new NoteCreateCapability(mac), 'Groceries\nmilk, eggs')).toBe('Created a note "Groceries".');
        expect(mac.scripts[0]).toContain('make new note');
    });

    it('falls back to the default container when the iCloud folder is missing', async () => {
        const mac = new FakeMacFailOnce();
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new NoteCreateCapability(mac), 'Idea')).toBe('Created a note "Idea".');
        expect(mac.scripts).toHaveLength(2);   // iCloud attempt failed, default succeeded
    });
});
