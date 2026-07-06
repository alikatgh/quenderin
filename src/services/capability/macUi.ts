import { MacAutomation, escapeAppleScriptString } from './macAutomation.js';

/**
 * The macOS GUI-driving seam — read the frontmost app's accessibility tree and click/type into ANY
 * app, not just the AppleScript-scriptable ones. This is the direct Cowork-parity capability
 * (screen → click), governed our way. Mirrors the Android `IDeviceProvider` seam: an interface with
 * a production implementation over macOS System Events (accessibility) and a fake for tests, so the
 * capability LOGIC (resolve-by-label, blocklist re-check, verify) is fully verifiable headless while
 * the one production-only surface is the osascript bridge — exactly like every other mac.* capability.
 */
export interface MacUiElement {
    /** The accessibility name (AXTitle/label) the user sees — the model targets this. */
    label: string;
    /** The AX role, e.g. "button", "menu item", "text field" — shown for context + disambiguation. */
    role: string;
}

export interface MacUi {
    available(): boolean;
    /** The named, actionable elements of the frontmost app's window. */
    observe(): Promise<MacUiElement[]>;
    /** Click the (unique) element with this accessibility name. */
    click(label: string): Promise<void>;
    /** Type text into whatever is focused. */
    typeText(text: string): Promise<void>;
    /** Press a whitelisted key: return, tab, or escape. */
    pressKey(key: string): Promise<void>;
    /** Click a menu-bar path, e.g. ["File", "Save As"] — the menu bar is a separate AX hierarchy. */
    clickMenu(path: string[]): Promise<void>;
}

/** macOS System Events implementation. The production-only bridge (needs Accessibility permission);
 *  built ON TOP of the hardened MacAutomation runner so escaping + execFile safety are reused. */
export class OsascriptMacUi implements MacUi {
    constructor(private readonly mac: MacAutomation) { }

    available(): boolean { return this.mac.available(); }

    async observe(): Promise<MacUiElement[]> {
        // Walk the front window's elements, emitting "role\tname" for each named one. `entire
        // contents` reaches nested elements; capped by the capability. Best-effort per element.
        const script = [
            'set out to ""',
            'tell application "System Events"',
            '  set frontProc to first application process whose frontmost is true',
            '  tell frontProc',
            '    try',
            '      set els to entire contents of front window',
            '    on error',
            '      set els to UI elements',
            '    end try',
            '    repeat with e in els',
            '      try',
            '        set n to name of e',
            '        if n is not missing value and n is not "" then set out to out & (role of e) & tab & n & linefeed',
            '      end try',
            '    end repeat',
            '  end tell',
            'end tell',
            'return out',
        ].join('\n');
        const raw = await this.mac.runAppleScript(script);
        // Split on the FIRST tab only, so a label that itself contains a tab is preserved intact
        // (role is always a single token) rather than silently dropped.
        const out: MacUiElement[] = [];
        for (const line of raw.split('\n')) {
            const i = line.indexOf('\t');
            if (i < 0) continue;
            const role = line.slice(0, i).trim();
            const label = line.slice(i + 1).trim();
            if (label) out.push({ role, label });
        }
        return out;
    }

    async click(label: string): Promise<void> {
        const esc = escapeAppleScriptString(label);
        const script = [
            'tell application "System Events"',
            '  tell (first application process whose frontmost is true)',
            '    try',
            '      set target to first UI element of entire contents of front window whose name is "' + esc + '"',
            '    on error',
            '      set target to first UI element whose name is "' + esc + '"',
            '    end try',
            '    click target',
            '  end tell',
            'end tell',
            'return "ok"',
        ].join('\n');
        await this.mac.runAppleScript(script);
    }

    async typeText(text: string): Promise<void> {
        await this.mac.runAppleScript(`tell application "System Events" to keystroke "${escapeAppleScriptString(text)}"`);
    }

    async clickMenu(path: string[]): Promise<void> {
        // v1: top menu > item (e.g. "File" > "Save As") — covers the overwhelming majority of tasks.
        const [menu, item] = path.map(escapeAppleScriptString);
        const script = [
            'tell application "System Events"',
            '  tell (first application process whose frontmost is true)',
            `    click menu item "${item}" of menu "${menu}" of menu bar 1`,
            '  end tell',
            'end tell',
            'return "ok"',
        ].join('\n');
        await this.mac.runAppleScript(script);
    }

    async pressKey(key: string): Promise<void> {
        // Navigation + confirm/dismiss keys — enough to move through lists and scroll panes, never a
        // character key (that's mac.ui.type) and never a destructive shortcut.
        const codes: Record<string, number> = {
            return: 36, tab: 48, escape: 53,
            up: 126, down: 125, left: 123, right: 124, pageup: 116, pagedown: 121,
        };
        const code = codes[key];
        if (code === undefined) throw new Error(`unsupported key: ${key}`);
        await this.mac.runAppleScript(`tell application "System Events" to key code ${code}`);
    }
}
