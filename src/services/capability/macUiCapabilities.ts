import { Capability, CapabilityTier, BlastRadius, ActionPreview } from './capability.js';
import { matchedBlockedKeyword } from './safety.js';
import { MacUi, MacUiElement } from './macUi.js';

/**
 * macOS GUI-driving capabilities — click and type into ANY app via the accessibility tree, not just
 * the AppleScript-scriptable ones. The Cowork-parity leap (screen → click), governed by the same
 * CapabilityRunner spine as everything else. The load-bearing safety property is the fs.move / app.tap
 * one: **the model taps by VISIBLE LABEL, never coordinates it makes up** — `mac.ui.tap("Send")`
 * resolves a real named element; a model cannot fabricate a pixel. Every resolved target is re-checked
 * against the blocklist (defense in depth) so an element named "Confirm payment" is refused even after
 * the input string passed. All tap/type/key are T2 → per-run approval.
 */

const NO_MAC = 'This runs on macOS only.';
const NO_PERMISSION = 'macOS blocked reading the screen — grant Quenderin Accessibility access in System Settings › Privacy & Security › Accessibility, then try again.';

/** T1: read the frontmost app's actionable elements. Perception — no approval. */
export class MacUiObserveCapability implements Capability {
    readonly name = 'mac.ui.observe';
    readonly purpose = 'List the clickable elements (buttons, menus, fields) of the frontmost macOS app. No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'the frontmost app screen' };

    constructor(private readonly ui: MacUi) { }

    async plan(): Promise<ActionPreview> {
        return { summary: 'Would read the frontmost app\'s on-screen elements (read-only).', mutates: false };
    }

    async run(): Promise<string> {
        if (!this.ui.available()) return NO_MAC;
        let els: MacUiElement[];
        try { els = await this.ui.observe(); } catch (e) { return describe(e); }
        if (els.length === 0) return 'No named elements on the frontmost window right now.';
        const lines = els.slice(0, 60).map(e => `- [${e.role}] ${e.label}`);
        return lines.join('\n') + (els.length > 60 ? `\n[…${els.length - 60} more]` : '');
    }
}

/** T2: click an element BY ITS VISIBLE LABEL. Per-run approval; verify() checks the screen changed. */
export class MacUiTapCapability implements Capability {
    readonly name = 'mac.ui.tap';
    readonly purpose = 'Click an element in the frontmost app by its visible label. Input: the label, e.g. "Send".';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the frontmost app' };

    private preTapSignature = '';

    constructor(private readonly ui: MacUi) { }

    async plan(input: string): Promise<ActionPreview> {
        if (!this.ui.available()) return { summary: NO_MAC, mutates: false };
        let els: MacUiElement[];
        try { els = await this.ui.observe(); } catch (e) { return { summary: describe(e), mutates: false }; }
        const resolved = resolve(els, input);
        if (typeof resolved === 'string') return { summary: resolved, mutates: false };
        return { summary: `Click "${resolved.label}" (${resolved.role}) in the frontmost app.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.ui.available()) return NO_MAC;
        let els: MacUiElement[];
        try { els = await this.ui.observe(); } catch (e) { return describe(e); }
        const resolved = resolve(els, input);
        if (typeof resolved === 'string') return resolved;
        // Defense in depth: re-check the RESOLVED element's real label+role. The runner already
        // scanned the input string; this catches an element that reads innocuous but is dangerous.
        const hit = matchedBlockedKeyword(`${resolved.label} ${resolved.role}`);
        if (hit) return `Refused: that element looks like a blocked action ('${hit}').`;
        this.preTapSignature = signature(els);
        try { await this.ui.click(resolved.label); } catch (e) { return describe(e); }
        return `Clicked "${resolved.label}".`;
    }

    /** Did the click do anything? A GUI click that silently doesn't register is the #1 failure —
     *  if the screen is byte-identical afterward, say so honestly rather than assume success. */
    async verify(): Promise<{ ok: boolean; detail: string }> {
        let after: MacUiElement[];
        try { after = await this.ui.observe(); } catch { return { ok: true, detail: 'could not re-read the screen' }; }
        if (signature(after) === this.preTapSignature) {
            return { ok: false, detail: 'the screen did not change — the click may not have registered' };
        }
        return { ok: true, detail: 'the screen changed as expected' };
    }
}

/** T2: type into the focused field. Per-run approval. */
export class MacUiTypeCapability implements Capability {
    readonly name = 'mac.ui.type';
    readonly purpose = 'Type text into the focused field of the frontmost macOS app. Input: the text to type.';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the frontmost app' };

    constructor(private readonly ui: MacUi) { }

    async plan(input: string): Promise<ActionPreview> {
        const text = input.trim();
        if (!text) return { summary: 'Input is the text to type.', mutates: false };
        const shown = text.length > 80 ? text.slice(0, 80) + '…' : text;
        return { summary: `Type "${shown}" into the focused field.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.ui.available()) return NO_MAC;
        const text = input.trim();
        if (!text) return 'Nothing to type.';
        try { await this.ui.typeText(text); } catch (e) { return describe(e); }
        const shown = text.length > 80 ? text.slice(0, 80) + '…' : text;
        return `Typed "${shown}".`;
    }
}

/** T2: click a menu-bar item, e.g. "File > Save As" — the menu bar reaches actions no window button
 *  exposes (Export, Select All, Preferences…). Per-run approval; the resolved item is blocklist-
 *  re-checked (so "File > Delete Everything" is refused). v1 is one level deep (Menu > Item). */
export class MacUiMenuCapability implements Capability {
    readonly name = 'mac.ui.menu';
    readonly purpose = 'Click a menu-bar item in the frontmost app. Input: "<Menu> > <Item>", e.g. "File > Save As".';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the frontmost app' };

    constructor(private readonly ui: MacUi) { }

    private parse(input: string): [string, string] | null {
        const parts = input.split('>').map(s => s.trim());
        return parts.length === 2 && parts[0] && parts[1] ? [parts[0], parts[1]] : null;
    }

    async plan(input: string): Promise<ActionPreview> {
        if (!this.ui.available()) return { summary: NO_MAC, mutates: false };
        const p = this.parse(input);
        return p ? { summary: `Click menu "${p[0]} > ${p[1]}" in the frontmost app.`, mutates: true }
                 : { summary: 'Input must be "<Menu> > <Item>", e.g. "File > Save As".', mutates: false };
    }

    async run(input: string): Promise<string> {
        if (!this.ui.available()) return NO_MAC;
        const p = this.parse(input);
        if (!p) return 'Input must be "<Menu> > <Item>", e.g. "File > Save As".';
        // Defense in depth: re-check the resolved menu path (the runner scanned the raw input too).
        const hit = matchedBlockedKeyword(`${p[0]} ${p[1]}`);
        if (hit) return `Refused: that menu item looks like a blocked action ('${hit}').`;
        try { await this.ui.clickMenu(p); } catch (e) { return describe(e); }
        return `Clicked menu "${p[0]} > ${p[1]}".`;
    }
}

/** T2: press a navigation key (return, tab, escape). Per-run approval — a key can submit or dismiss. */
export class MacUiKeyCapability implements Capability {
    readonly name = 'mac.ui.key';
    readonly purpose = 'Press a key in the frontmost macOS app. Input: return, tab, escape, up, down, left, right, pageup, or pagedown.';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the frontmost app' };

    private static readonly ALLOWED = new Set(['return', 'tab', 'escape', 'up', 'down', 'left', 'right', 'pageup', 'pagedown']);

    constructor(private readonly ui: MacUi) { }

    async plan(input: string): Promise<ActionPreview> {
        const key = input.trim().toLowerCase();
        if (!MacUiKeyCapability.ALLOWED.has(key)) return { summary: 'Input must be a navigation key (return, tab, escape, up, down, left, right, pageup, pagedown).', mutates: false };
        return { summary: `Press the "${key}" key.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.ui.available()) return NO_MAC;
        const key = input.trim().toLowerCase();
        if (!MacUiKeyCapability.ALLOWED.has(key)) return 'Input must be a navigation key: return, tab, escape, up, down, left, right, pageup, pagedown.';
        try { await this.ui.pressKey(key); } catch (e) { return describe(e); }
        return `Pressed "${key}".`;
    }
}

// ─── shared helpers ─────────────────────────────────────────────────────────────────────────

/** Resolve a visible label to exactly one element, or an explanation (mirrors app.tap). */
function resolve(els: MacUiElement[], input: string): MacUiElement | string {
    const query = input.trim().toLowerCase();
    if (!query) return 'Input is the visible label of the element to click.';
    const exact = els.filter(e => e.label.toLowerCase() === query);
    const partial = els.filter(e => e.label.toLowerCase().includes(query));
    const matches = exact.length > 0 ? exact : partial;
    if (matches.length === 0) return `No element labeled "${input}". Use mac.ui.observe to see what's on screen.`;
    if (matches.length > 1) return `"${input}" matches ${matches.length} elements — be more specific.`;
    return matches[0];
}

/** A stable fingerprint of the screen — used to tell if a click changed anything. */
function signature(els: MacUiElement[]): string {
    return els.map(e => `${e.role}:${e.label}`).sort().join('|');
}

function describe(e: unknown): string {
    const msg = (e as Error)?.message ?? String(e);
    if (/not allowed|Not authori|-1743|assistive|accessibility/i.test(msg)) return NO_PERMISSION;
    return `Couldn't drive the app: ${msg}`;
}

/** The macOS GUI-driving toolkit — observe (T1) + tap/type/key (T2), all on one accessibility seam. */
export function macUiCapabilities(ui: MacUi): Capability[] {
    return [
        new MacUiObserveCapability(ui),
        new MacUiTapCapability(ui),
        new MacUiTypeCapability(ui),
        new MacUiKeyCapability(ui),
        new MacUiMenuCapability(ui),
    ];
}
