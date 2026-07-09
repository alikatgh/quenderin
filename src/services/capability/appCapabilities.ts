import { IDeviceProvider, UIElement } from '../../types/index.js';
import { UiParserService } from '../uiParser.service.js';
import { Capability, CapabilityTier, BlastRadius, ActionPreview } from './capability.js';
import { matchedBlockedKeyword } from './safety.js';

/**
 * App-driving capabilities over the hardened ADB `IDeviceProvider` (BlueStacks, an emulator, or a
 * real device — anything that speaks ADB). This is the reusable core under EVERY "drive an app"
 * task (the imo/BlueStacks forcing example in AGENT_AUTONOMY_PLAN §4b), governed by the same
 * CapabilityRunner spine as the file capabilities.
 *
 * The load-bearing safety property, mirrored from fs.move: **the model taps by VISIBLE TEXT, never
 * by coordinates it makes up.** `app.tap("Add friend")` resolves the on-screen element; a model
 * cannot fabricate a pixel to hit. And every resolved target is re-checked against the blocklist
 * (defense in depth) so a button reading "OK" but resource-id'd `confirm_payment_btn` is refused.
 */

/** Read the current screen's actionable elements — the perception half of "drive this app". */
export class AppObserveCapability implements Capability {
    readonly name = 'app.observe';
    readonly purpose = 'List the tappable elements on the connected app screen (BlueStacks/emulator/device). No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'the connected device screen' };

    constructor(private readonly device: IDeviceProvider, private readonly parser: UiParserService) { }

    async plan(): Promise<ActionPreview> {
        return { summary: 'Would read the current screen of the connected app (read-only).', mutates: false };
    }

    async run(): Promise<string> {
        const elements = await readScreen(this.device, this.parser);
        if (elements === null) return NO_DEVICE;
        const actionable = elements.filter(e => e.visible && (e.clickable || e.text || e.contentDesc));
        if (actionable.length === 0) return 'The screen has no readable elements right now.';
        const lines = actionable.slice(0, 60).map(e => {
            const label = e.text || e.contentDesc || `(${e.className.split('.').pop()})`;
            const kind = e.clickable ? 'tap' : 'text';
            return `- [${kind}] ${label}`;
        });
        const more = actionable.length > 60 ? `\n[…${actionable.length - 60} more]` : '';
        return lines.join('\n') + more;
    }
}

/** Tap an element BY ITS VISIBLE LABEL. T2 (drives another app) → per-run approval. */
export class AppTapCapability implements Capability {
    readonly name = 'app.tap';
    readonly purpose = 'Tap an on-screen element by its visible text. Input: the label, e.g. "Add friend".';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the connected app' };

    constructor(private readonly device: IDeviceProvider, private readonly parser: UiParserService) { }

    /** Signature of the screen just before the tap — verify() compares against the after-state. */
    private preTapSignature = '';

    async plan(input: string): Promise<ActionPreview> {
        const resolved = await this.resolve(input);
        if (typeof resolved === 'string') return { summary: resolved, mutates: false };
        return { summary: `Tap "${labelOf(resolved)}" in the connected app.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        const elements = await readScreen(this.device, this.parser);
        if (elements === null) return NO_DEVICE;
        const resolved = this.resolveIn(elements, input);
        if (typeof resolved === 'string') return resolved;
        // Defense in depth: re-check the RESOLVED element's real text/desc/resource-id — a button
        // reading "OK" may be a payment confirm. The runner already checked the input string.
        const hit = matchedBlockedKeyword([resolved.text, resolved.contentDesc, resolved.resourceId].filter(Boolean).join(' '));
        if (hit) return `Refused: that element looks like a blocked action ('${hit}').`;
        this.preTapSignature = screenSignature(elements);   // remember for verify()
        await this.device.click(resolved.center.x, resolved.center.y);
        return `Tapped "${labelOf(resolved)}".`;
    }

    /** Did the tap DO anything? The #1 silent failure in GUI automation is a tap that doesn't
     *  register (wrong coords, element not actually hittable). If the screen is byte-identical
     *  after the tap, warn — better an honest "couldn't confirm" than a false success. */
    async verify(): Promise<{ ok: boolean; detail: string }> {
        const after = await readScreen(this.device, this.parser);
        if (after === null) return { ok: true, detail: 'device went away' };   // can't check → don't cry wolf
        if (screenSignature(after) === this.preTapSignature) {
            return { ok: false, detail: 'the screen did not change — the tap may not have registered' };
        }
        return { ok: true, detail: 'the screen changed as expected' };
    }

    /** Read the screen, then resolve — used by plan() (run() reads once and calls resolveIn). */
    private async resolve(input: string): Promise<UIElement | string> {
        const elements = await readScreen(this.device, this.parser);
        if (elements === null) return NO_DEVICE;
        return this.resolveIn(elements, input);
    }

    /** Resolve a visible label to exactly one clickable element in `elements`, or an explanation. */
    private resolveIn(elements: UIElement[], input: string): UIElement | string {
        const query = input.trim().toLowerCase();
        if (!query) return 'Input is the visible label of the element to tap.';
        const clickable = elements.filter(e => e.visible && e.clickable);
        const exact = clickable.filter(e => labelOf(e).toLowerCase() === query);
        const partial = clickable.filter(e => labelOf(e).toLowerCase().includes(query));
        const matches = exact.length > 0 ? exact : partial;
        if (matches.length === 0) return `No tappable element labeled "${input}". Use app.observe to see what's on screen.`;
        if (matches.length > 1) return `"${input}" matches ${matches.length} elements — be more specific.`;
        return matches[0];
    }
}

/** Type into the currently-focused field. T2 → per-run approval. verify() prefers positive
 *  evidence (typed text visible) then falls back to a screen-change check. */
export class AppTypeCapability implements Capability {
    readonly name = 'app.type';
    readonly purpose = 'Type text into the focused field of the connected app. Input: the text to type.';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the connected app' };

    private preSignature = '';
    private lastTyped = '';

    constructor(
        private readonly device: IDeviceProvider,
        private readonly parser: UiParserService,
    ) { }

    async plan(input: string): Promise<ActionPreview> {
        const text = input.trim();
        if (!text) return { summary: 'Input is the text to type.', mutates: false };
        const shown = text.length > 80 ? text.slice(0, 80) + '…' : text;
        return { summary: `Type "${shown}" into the focused field.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        const text = input.trim();
        if (!text) return 'Nothing to type.';
        const before = await readScreen(this.device, this.parser);
        this.preSignature = before ? screenSignature(before) : '';
        this.lastTyped = text;
        try {
            await this.device.type(text);
        } catch (e) {
            return isNoDevice(e) ? NO_DEVICE : `Couldn't type: ${String(e)}`;
        }
        const shown = text.length > 80 ? text.slice(0, 80) + '…' : text;
        return `Typed "${shown}".`;
    }

    async verify(): Promise<{ ok: boolean; detail: string }> {
        const after = await readScreen(this.device, this.parser);
        if (after === null) return { ok: true, detail: 'device went away' };
        const needle = this.lastTyped.slice(0, Math.min(40, this.lastTyped.length));
        if (needle && after.some(e => {
            const hay = `${e.text || ''} ${e.contentDesc || ''}`;
            return hay.includes(needle);
        })) {
            return { ok: true, detail: 'typed text is visible on screen' };
        }
        if (this.preSignature && screenSignature(after) === this.preSignature) {
            return { ok: false, detail: 'the screen did not change and typed text is not visible — type may not have registered' };
        }
        return { ok: true, detail: 'the screen changed as expected' };
    }
}

/** Press a hardware/navigation key. T2 → per-run approval (a key can submit or dismiss).
 *  verify() checks the screen changed for back/enter/home (all of these typically navigate). */
export class AppKeyCapability implements Capability {
    readonly name = 'app.key';
    readonly purpose = 'Press a navigation key on the connected app. Input: one of back, enter, home.';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the connected app' };

    private static readonly ALLOWED = new Set(['back', 'enter', 'home']);

    private preSignature = '';

    constructor(
        private readonly device: IDeviceProvider,
        private readonly parser: UiParserService,
    ) { }

    async plan(input: string): Promise<ActionPreview> {
        const key = input.trim().toLowerCase();
        if (!AppKeyCapability.ALLOWED.has(key)) return { summary: 'Input must be one of: back, enter, home.', mutates: false };
        return { summary: `Press the "${key}" key.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        const key = input.trim().toLowerCase();
        if (!AppKeyCapability.ALLOWED.has(key)) return 'Input must be one of: back, enter, home.';
        const before = await readScreen(this.device, this.parser);
        this.preSignature = before ? screenSignature(before) : '';
        try {
            await this.device.pressKey(key);
        } catch (e) {
            return isNoDevice(e) ? NO_DEVICE : `Couldn't press ${key}: ${String(e)}`;
        }
        return `Pressed "${key}".`;
    }

    async verify(): Promise<{ ok: boolean; detail: string }> {
        const after = await readScreen(this.device, this.parser);
        if (after === null) return { ok: true, detail: 'device went away' };
        if (this.preSignature && screenSignature(after) === this.preSignature) {
            return { ok: false, detail: 'the screen did not change — the key may not have registered' };
        }
        return { ok: true, detail: 'the screen changed as expected' };
    }
}

// ─── shared helpers ─────────────────────────────────────────────────────────────────────────

const NO_DEVICE = 'No app is connected. Start BlueStacks (or an emulator/device) and make sure ADB sees it, then try again.';

function labelOf(e: UIElement): string {
    return e.text || e.contentDesc || `(${e.className.split('.').pop() ?? 'element'})`;
}

/** A stable fingerprint of the visible+clickable screen — used to tell if a tap changed anything. */
function screenSignature(elements: UIElement[]): string {
    return elements
        .filter(e => e.visible)
        .map(e => `${labelOf(e)}@${e.center.x},${e.center.y}`)
        .sort()
        .join('|');
}

function isNoDevice(e: unknown): boolean {
    const code = (e as { code?: string })?.code;
    return code === 'ADB_MISSING' || code === 'ADB_TIMEOUT';
}

/** Read + parse the current screen, or null when no device is reachable. */
async function readScreen(device: IDeviceProvider, parser: UiParserService): Promise<UIElement[] | null> {
    try {
        const { xml } = await device.getScreenContext();
        if (!xml) return [];
        return parser.parseUI(xml).elements;
    } catch (e) {
        if (isNoDevice(e)) return null;
        return [];
    }
}

/** The app-driving toolkit — observe (T1) + tap/type/key (T2), all on one provider. */
export function appCapabilities(device: IDeviceProvider, parser: UiParserService): Capability[] {
    return [
        new AppObserveCapability(device, parser),
        new AppTapCapability(device, parser),
        new AppTypeCapability(device, parser),
        new AppKeyCapability(device, parser),
    ];
}
