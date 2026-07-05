import { EventEmitter } from 'events';
import { describe, it, expect } from 'vitest';
import type { IDeviceProvider } from '../src/types/index.js';
import { UiParserService } from '../src/services/uiParser.service.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { InMemoryConsentStore, InMemoryAuditLedger, Capability, CapabilityTier } from '../src/services/capability/capability.js';
import { AppTapCapability } from '../src/services/capability/appCapabilities.js';

/**
 * The agent checks its own work — the reliability lever against our honest weakness (a weak local
 * model makes clumsy actions). A verifying agent NOTICES a tap that silently didn't register and
 * says so, where a naive cloud agent assumes success.
 */

/** A fake device that can change (or NOT change) its screen after a tap. */
class SwitchingDevice extends EventEmitter implements IDeviceProvider {
    taps: Array<[number, number]> = [];
    constructor(private screens: string[]) { super(); }   // screens[0] before tap, screens[1] after
    private i = 0;
    async click(x: number, y: number) { this.taps.push([x, y]); if (this.i < this.screens.length - 1) this.i++; }
    async type() {}
    async scroll() {}
    async pressKey() {}
    async getScreenContext() { return { xml: this.screens[this.i], screenshotPath: '' }; }
}

const BEFORE = `<hierarchy>
  <node text="Menu" class="a.B" clickable="true" bounds="[0,0][100,50]" />
  <node text="Home" class="a.B" clickable="true" bounds="[0,60][100,110]" />
</hierarchy>`;
const AFTER = `<hierarchy>
  <node text="Settings" class="a.B" clickable="true" bounds="[0,0][100,50]" />
  <node text="Back" class="a.B" clickable="true" bounds="[0,60][100,110]" />
</hierarchy>`;

const parser = new UiParserService();
const grant = () => { const c = new InMemoryConsentStore(); c.setGranted('app.tap', true); return c; };

describe('app.tap self-verification', () => {
    it('confirms silently when the screen changed after the tap', async () => {
        const device = new SwitchingDevice([BEFORE, AFTER]);   // tap flips to AFTER
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(new AppTapCapability(device, parser), 'Menu');
        expect(out).toBe('Tapped "Menu".');   // no warning — it worked
    });

    it('WARNS when the screen did not change — a tap that may not have registered', async () => {
        const device = new SwitchingDevice([BEFORE]);   // screen never changes (only one state)
        const ledger = new InMemoryAuditLedger();
        const runner = new CapabilityRunner(grant(), ledger, async () => true);
        const out = await runner.execute(new AppTapCapability(device, parser), 'Menu');
        expect(out).toContain('Tapped "Menu".');
        expect(out).toContain("Couldn't confirm it worked: the screen did not change");
        expect(ledger.entries().some(e => e.decision === 'unverified')).toBe(true);
    });
});

describe('generic verification plumbing', () => {
    class VerifyCap implements Capability {
        readonly name = 'test.v'; readonly purpose = 't';
        readonly tier = CapabilityTier.ReversibleWrite;
        readonly blastRadius = { kind: 'write' as const, resource: 't' };
        constructor(private readonly ok: boolean, private readonly throws = false) {}
        async plan() { return { summary: 'do', mutates: true }; }
        async run() { return 'did it'; }
        async verify() { if (this.throws) throw new Error('cant check'); return { ok: this.ok, detail: this.ok ? 'confirmed' : 'nope' }; }
    }
    const consent = () => { const c = new InMemoryConsentStore(); c.setGranted('test.v', true); return c; };

    it('annotates + ledgers when verify reports failure', async () => {
        const ledger = new InMemoryAuditLedger();
        const out = await new CapabilityRunner(consent(), ledger, async () => true).execute(new VerifyCap(false), 'x');
        expect(out).toBe('did it\n(Couldn\'t confirm it worked: nope)');
        expect(ledger.entries().map(e => e.decision)).toEqual(['allowed', 'unverified']);
    });

    it('is best-effort: a throwing verify does not fail the action', async () => {
        const out = await new CapabilityRunner(consent(), new InMemoryAuditLedger(), async () => true).execute(new VerifyCap(true, true), 'x');
        expect(out).toBe('did it');   // action succeeded; verification quietly gave up
    });

    it('stays silent when verify passes', async () => {
        const out = await new CapabilityRunner(consent(), new InMemoryAuditLedger(), async () => true).execute(new VerifyCap(true), 'x');
        expect(out).toBe('did it');
    });
});
