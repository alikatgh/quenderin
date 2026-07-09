import { EventEmitter } from 'events';
import { describe, it, expect } from 'vitest';
import type { IDeviceProvider } from '../src/types/index.js';
import { UiParserService } from '../src/services/uiParser.service.js';
import { CapabilityRunner } from '../src/services/capability/runner.js';
import { InMemoryConsentStore, InMemoryAuditLedger } from '../src/services/capability/capability.js';
import {
    AppObserveCapability, AppTapCapability, AppTypeCapability, AppKeyCapability,
} from '../src/services/capability/appCapabilities.js';

/** A fake ADB provider: serves a canned UI dump and records every action. No emulator needed. */
class FakeDevice extends EventEmitter implements IDeviceProvider {
    taps: Array<[number, number]> = [];
    typed: string[] = [];
    keys: string[] = [];
    constructor(private xml: string, private failCode?: string) { super(); }
    async click(x: number, y: number) { this.guard(); this.taps.push([x, y]); }
    async type(text: string) { this.guard(); this.typed.push(text); }
    async scroll() { this.guard(); }
    async pressKey(key: string) { this.guard(); this.keys.push(key); }
    async getScreenContext() { this.guard(); return { xml: this.xml, screenshotPath: '' }; }
    private guard() { if (this.failCode) { const e = new Error('adb') as Error & { code?: string }; e.code = this.failCode; throw e; } }
}

// A tiny imo-like screen: an "Add friend" button, a message field, and an innocuous "Pinboard".
const SCREEN = `<?xml version="1.0"?>
<hierarchy>
  <node text="Add friend" resource-id="add_friend_btn" class="android.widget.Button" clickable="true" bounds="[40,100][300,180]" />
  <node text="Pinboard" resource-id="pin_board" class="android.widget.TextView" clickable="true" bounds="[40,200][300,260]" />
  <node text="" content-desc="Message" resource-id="msg_input" class="android.widget.EditText" clickable="true" bounds="[40,300][680,380]" />
  <node text="Confirm" resource-id="confirm_payment_btn" class="android.widget.Button" clickable="true" bounds="[40,400][300,480]" />
</hierarchy>`;

const parser = new UiParserService();

describe('app.observe (T1)', () => {
    it('lists tappable elements without needing approval', async () => {
        const device = new FakeDevice(SCREEN);
        const consent = new InMemoryConsentStore(); consent.setGranted('app.observe', true);
        const runner = new CapabilityRunner(consent);   // no approver — fine for a read
        const out = await runner.execute(new AppObserveCapability(device, parser), '');
        expect(out).toContain('[tap] Add friend');
        expect(out).toContain('Message');   // content-desc used when text is empty
    });

    it('reports a helpful message when no device is connected', async () => {
        const device = new FakeDevice(SCREEN, 'ADB_MISSING');
        const out = await new AppObserveCapability(device, parser).run();
        expect(out).toContain('No app is connected');
    });
});

describe('app.tap (T2 — by visible text, never coordinates)', () => {
    const cap = (d: FakeDevice) => new AppTapCapability(d, parser);
    const grant = () => { const c = new InMemoryConsentStore(); c.setGranted('app.tap', true); return c; };

    it('resolves a label to its element and taps its center after approval', async () => {
        const device = new FakeDevice(SCREEN);
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(cap(device), 'Add friend');
        // With a static fake screen the tap can't be visually confirmed, so verification honestly
        // appends a "couldn't confirm" note — the action still ran and tapped the right center.
        expect(out).toContain('Tapped "Add friend".');
        expect(device.taps).toEqual([[170, 140]]);   // center of [40,100][300,180]
    });

    it('FAILS CLOSED without an approver — nothing is tapped', async () => {
        const device = new FakeDevice(SCREEN);
        const ledger = new InMemoryAuditLedger();
        const runner = new CapabilityRunner(grant(), ledger);   // no approver
        const out = await runner.execute(cap(device), 'Add friend');
        expect(out).toContain('needs your per-run approval');
        expect(device.taps).toHaveLength(0);
        expect(ledger.entries().at(-1)?.decision).toBe('needsApproval');
    });

    it('re-checks the RESOLVED element against the blocklist (a "Confirm" that is a payment)', async () => {
        const device = new FakeDevice(SCREEN);
        const runner = new CapabilityRunner(grant(), new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(cap(device), 'Confirm');
        expect(out).toContain('blocked action');
        expect(device.taps).toHaveLength(0);   // never tapped despite approval
    });

    it('refuses an unknown label and refuses an ambiguous one', async () => {
        const device = new FakeDevice(SCREEN);
        expect(await cap(device).run('nonexistent')).toContain('No tappable element');
        const ambiguous = new FakeDevice(`<hierarchy>
            <node text="Send" class="a.B" clickable="true" bounds="[0,0][10,10]" />
            <node text="Send" class="a.B" clickable="true" bounds="[0,20][10,30]" />
        </hierarchy>`);
        expect(await cap(ambiguous).run('Send')).toContain('be more specific');
    });
});

describe('app.type + app.key (T2)', () => {
    it('types after approval and records the keystroke', async () => {
        const device = new FakeDevice(SCREEN);
        const consent = new InMemoryConsentStore();
        consent.setGranted('app.type', true); consent.setGranted('app.key', true);
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async () => true);

        expect(await runner.execute(new AppTypeCapability(device, parser), 'hey, adding you')).toContain('Typed');
        expect(device.typed).toEqual(['hey, adding you']);

        // Static fake screen → verify annotates (enter didn't change the dump); action still ran.
        expect(await runner.execute(new AppKeyCapability(device, parser), 'enter')).toContain('Pressed "enter"');
        expect(device.keys).toEqual(['enter']);
        expect(await new AppKeyCapability(device, parser).run('reboot')).toContain('back, enter, home');
    });

    it('blocks a message whose text touches the blocklist (via the runner)', async () => {
        const device = new FakeDevice(SCREEN);
        const consent = new InMemoryConsentStore(); consent.setGranted('app.type', true);
        const runner = new CapabilityRunner(consent, new InMemoryAuditLedger(), async () => true);
        const out = await runner.execute(new AppTypeCapability(device, parser), 'send me your password');
        expect(out).toContain("blocked action ('password')");
        expect(device.typed).toHaveLength(0);
    });
});

describe('a friend-request plan: one approval drives the app end to end', () => {
    it('taps, types, and presses enter under a single aggregate approval', async () => {
        const device = new FakeDevice(SCREEN);
        const consent = new InMemoryConsentStore();
        ['app.tap', 'app.type', 'app.key'].forEach(id => consent.setGranted(id, true));
        const ledger = new InMemoryAuditLedger();
        let approvals = 0;
        const runner = new CapabilityRunner(consent, ledger, async (p) => {
            approvals++;
            expect(p.summary).toContain('1. Tap "Add friend"');
            expect(p.summary).toContain('2. Type');
            return true;
        });
        const out = await runner.executePlan([
            { capability: new AppTapCapability(device, parser), input: 'Add friend' },
            { capability: new AppTypeCapability(device, parser), input: 'hi from quenderin' },
            { capability: new AppKeyCapability(device, parser), input: 'enter' },
        ]);
        expect(approvals).toBe(1);
        expect(out).toContain('1. Tapped');
        expect(device.taps).toEqual([[170, 140]]);
        expect(device.typed).toEqual(['hi from quenderin']);
        expect(device.keys).toEqual(['enter']);
        // 3 actions ran (tap, type, key); the tap also logs an 'unverified' note on the static
        // fake screen — filter to the executions themselves.
        expect(ledger.entries().filter(e => e.decision === 'allowed')).toHaveLength(3);
    });
});
