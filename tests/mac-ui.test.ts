import { describe, it, expect } from 'vitest';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import { MacUi, MacUiElement } from '../src/services/capability/macUi.js';
import {
    MacUiObserveCapability, MacUiTapCapability, MacUiTypeCapability, MacUiKeyCapability,
} from '../src/services/capability/macUiCapabilities.js';

/**
 * macOS GUI-driving — the Cowork-parity leap (click/type into ANY app), governed the same way as
 * the Android app.* twins. A fake accessibility seam makes the capability LOGIC fully verifiable
 * headless; the only production-only surface is the osascript bridge. Pins tap-by-label resolution,
 * the defense-in-depth blocklist re-check, fail-closed approval, and the did-it-register verify.
 */
class FakeMacUi implements MacUi {
    clicks: string[] = []; typed: string[] = []; keys: string[] = [];
    private clicked = false;
    constructor(private readonly els: MacUiElement[], private readonly opts: { avail?: boolean; failObserve?: string; elsAfter?: MacUiElement[] } = {}) { }
    available(): boolean { return this.opts.avail ?? true; }
    async observe(): Promise<MacUiElement[]> {
        if (this.opts.failObserve) throw new Error(this.opts.failObserve);
        return this.clicked && this.opts.elsAfter ? this.opts.elsAfter : this.els;
    }
    async click(label: string): Promise<void> { this.clicks.push(label); this.clicked = true; }
    async typeText(t: string): Promise<void> { this.typed.push(t); }
    async pressKey(k: string): Promise<void> { this.keys.push(k); }
}

const el = (label: string, role = 'button'): MacUiElement => ({ label, role });
const grant = (...ids: string[]) => { const c = new InMemoryConsentStore(); ids.forEach(id => c.setGranted(id, true)); return c; };

describe('mac.ui.observe (T1 — perception, no approval)', () => {
    it('lists the frontmost app elements as "[role] label"', async () => {
        const ui = new FakeMacUi([el('Send', 'button'), el('Subject', 'text field')]);
        const out = await new CapabilityRunner(grant('mac.ui.observe')).execute(new MacUiObserveCapability(ui), '');
        expect(out).toBe('- [button] Send\n- [text field] Subject');
    });

    it('handles an empty window and a denied Accessibility permission', async () => {
        expect(await new MacUiObserveCapability(new FakeMacUi([])).run()).toContain('No named elements');
        const denied = new FakeMacUi([], { failObserve: 'osascript: not allowed assistive access (-1743)' });
        expect(await new MacUiObserveCapability(denied).run()).toContain('Accessibility');
    });
});

describe('mac.ui.tap (T2 — click by visible label, approved & injection-safe)', () => {
    it('resolves the label and clicks only after approval', async () => {
        const ui = new FakeMacUi([el('Send'), el('Cancel')]);
        const runner = new CapabilityRunner(grant('mac.ui.tap'), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new MacUiTapCapability(ui), 'Send')).toContain('Clicked "Send"');
        expect(ui.clicks).toEqual(['Send']);
    });

    it('FAILS CLOSED without an approver — nothing is clicked', async () => {
        const ui = new FakeMacUi([el('Send')]);
        const ledger = new InMemoryAuditLedger();
        const out = await new CapabilityRunner(grant('mac.ui.tap'), ledger).execute(new MacUiTapCapability(ui), 'Send');
        expect(out).toContain('per-run approval');
        expect(ui.clicks).toHaveLength(0);
        expect(ledger.entries().at(-1)?.decision).toBe('needsApproval');
    });

    it('rejects an ambiguous or missing label before clicking', async () => {
        // "Save" partial-matches both and exactly matches neither → ambiguous (an exact match would win).
        const ambiguous = new FakeMacUi([el('Save File'), el('Save As')]);
        expect(await new MacUiTapCapability(ambiguous).run('Save')).toContain('matches 2 elements');
        const missing = new FakeMacUi([el('OK')]);
        expect(await new MacUiTapCapability(missing).run('Nope')).toContain('No element labeled');
        expect(ambiguous.clicks).toHaveLength(0);
    });

    it('an EXACT label wins even when it is a substring of others (clicks the exact one)', async () => {
        const ui = new FakeMacUi([el('Save'), el('Save As')]);
        const runner = new CapabilityRunner(grant('mac.ui.tap'), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new MacUiTapCapability(ui), 'Save')).toContain('Clicked "Save"');
        expect(ui.clicks).toEqual(['Save']);   // not the ambiguous "Save As"
    });

    it('defense in depth: an innocuous input that RESOLVES to a blocked element is refused', async () => {
        // "Send" passes the runner's blocklist, but it partial-matches the element "Send payment",
        // whose re-checked label trips 'payment' — so the resolved target is refused, nothing clicked.
        const ui = new FakeMacUi([el('Send payment')]);
        const runner = new CapabilityRunner(grant('mac.ui.tap'), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(new MacUiTapCapability(ui), 'Send');
        expect(out).toContain("blocked action ('payment')");
        expect(ui.clicks).toHaveLength(0);
    });

    it('verify() flags a click that did not change the screen, and confirms one that did', async () => {
        const stuck = new FakeMacUi([el('Send')]);                       // observe returns same els after click
        await stuck.click('Send');
        const tapStuck = new MacUiTapCapability(stuck);
        await tapStuck.run('Send');
        expect((await tapStuck.verify()).ok).toBe(false);

        const worked = new FakeMacUi([el('Send')], { elsAfter: [el('Sent')] });
        const tapWorked = new MacUiTapCapability(worked);
        await tapWorked.run('Send');
        expect((await tapWorked.verify()).ok).toBe(true);
    });
});

describe('mac.ui.type + mac.ui.key (T2)', () => {
    it('types into the focused field after approval', async () => {
        const ui = new FakeMacUi([]);
        const runner = new CapabilityRunner(grant('mac.ui.type'), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new MacUiTypeCapability(ui), 'hello world')).toContain('Typed "hello world"');
        expect(ui.typed).toEqual(['hello world']);
    });

    it('presses only whitelisted keys', async () => {
        const ui = new FakeMacUi([]);
        const runner = new CapabilityRunner(grant('mac.ui.key'), new InMemoryAuditLedger(), async () => true);
        expect(await runner.execute(new MacUiKeyCapability(ui), 'return')).toContain('Pressed "return"');
        expect(ui.keys).toEqual(['return']);
        expect(await new MacUiKeyCapability(ui).run('delete-everything')).toContain('return, tab, escape');
    });

    it('every mac.ui.* action is macOS-only off darwin', async () => {
        const off = new FakeMacUi([], { avail: false });
        expect(await new MacUiTapCapability(off).run('x')).toBe('This runs on macOS only.');
        expect(await new MacUiTypeCapability(off).run('x')).toBe('This runs on macOS only.');
    });
});
