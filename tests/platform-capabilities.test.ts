import { describe, it, expect } from 'vitest';
import os from 'os';
import { CommandRunner, powershell } from '../src/services/capability/platformAutomation.js';
import {
    platformCapabilities,
    WinClipboardReadCapability, WinOpenAppCapability, WinOpenURLCapability, WinExplorerRevealCapability,
    WinFrontWindowCapability,
    LinuxClipboardReadCapability, LinuxOpenURLCapability, LinuxNotifyCapability, LinuxFilesRevealCapability,
    LinuxFrontWindowCapability,
} from '../src/services/capability/platformCapabilities.js';
import { createGovernedAgent, ChatCompleter } from '../src/services/capability/desktopAgent.js';
import { InMemoryConsentStore } from '../src/services/capability/capability.js';

/**
 * The win.* / linux.* libraries over a fake runner — the Windows/Linux port of the mission layer.
 * The load-bearing assertions are the INJECTION-STANCE ones: every invocation must be a fixed
 * command whose user values are separate argv elements or environment variables — a hostile value
 * must never appear inside a command/script string.
 */

class FakeRunner implements CommandRunner {
    calls: Array<{ argv: string[]; env?: Record<string, string> }> = [];
    replies: Array<{ ok?: string; err?: { code: string; message?: string } }>;
    private readonly os: NodeJS.Platform;
    constructor(platform: NodeJS.Platform, replies: Array<{ ok?: string; err?: { code: string; message?: string } }> = [{ ok: '' }]) {
        this.os = platform;
        this.replies = replies;
    }
    platform(): NodeJS.Platform { return this.os; }
    available(): boolean { return this.os === 'win32' || this.os === 'linux'; }
    async run(argv: string[], env?: Record<string, string>): Promise<string> {
        this.calls.push({ argv, env });
        const reply = this.replies.length > 1 ? this.replies.shift()! : this.replies[0];
        if (reply.err) throw Object.assign(new Error(reply.err.message ?? reply.err.code), { code: reply.err.code, binary: argv[0] });
        return reply.ok ?? '';
    }
}

describe('the injection stance — fixed commands, values as data', () => {
    it('win.app.open passes a hostile name ONLY as an environment value, never in the script', async () => {
        const shell = new FakeRunner('win32');
        const hostile = 'notepad"; Remove-Item -Recurse C:\\ #';
        await new WinOpenAppCapability(shell).run(hostile);
        const call = shell.calls[0];
        // The PowerShell script is byte-for-byte the FIXED template…
        expect(call.argv).toEqual(powershell('Start-Process -FilePath $env:QUENDERIN_APP'));
        expect(call.argv.join(' ')).not.toContain('Remove-Item');
        // …and the hostile value rides the env channel, where PowerShell treats it as data.
        expect(call.env).toEqual({ QUENDERIN_APP: hostile });
    });

    it('win/linux URL opens carry the URL as its own argv element and refuse non-http(s)', async () => {
        const win = new FakeRunner('win32');
        await new WinOpenURLCapability(win).run('https://quenderin.org/help');
        expect(win.calls[0].argv).toEqual(['rundll32', 'url.dll,FileProtocolHandler', 'https://quenderin.org/help']);

        const linux = new FakeRunner('linux');
        await new LinuxOpenURLCapability(linux).run('https://quenderin.org/help');
        expect(linux.calls[0].argv).toEqual(['xdg-open', 'https://quenderin.org/help']);

        for (const bad of ['file:///etc/passwd', 'javascript:alert(1)', 'https://a b.com', '$(reboot)']) {
            const w = await new WinOpenURLCapability(new FakeRunner('win32')).run(bad);
            const l = await new LinuxOpenURLCapability(new FakeRunner('linux')).run(bad);
            expect(w).toContain('http(s) URL');
            expect(l).toContain('http(s) URL');
        }
    });

    it('linux.notify.send passes title and body as separate argv elements', async () => {
        const shell = new FakeRunner('linux');
        await new LinuxNotifyCapability(shell).run('Done | moved 12 files; $(rm -rf ~) stays literal');
        expect(shell.calls[0].argv).toEqual(['notify-send', 'Done', 'moved 12 files; $(rm -rf ~) stays literal']);
    });

    it('reveal capabilities reject control characters in paths', async () => {
        const win = await new WinExplorerRevealCapability(new FakeRunner('win32')).run('C:\\badpath');
        expect(win).toContain('Input is a file or folder path');
        const linux = await new LinuxFilesRevealCapability(new FakeRunner('linux')).run('/badpath');
        expect(linux).toContain('Input is a file or folder path');
    });
});

describe('platform behavior', () => {
    it('win.clipboard.read runs the fixed Get-Clipboard script and truncates long text', async () => {
        const long = 'x'.repeat(5000);
        const shell = new FakeRunner('win32', [{ ok: long }]);
        const out = await new WinClipboardReadCapability(shell).run();
        expect(shell.calls[0].argv).toEqual(powershell('Get-Clipboard -Raw'));
        expect(out.endsWith('[…clipboard truncated]')).toBe(true);
        expect(out.length).toBeLessThan(4100);
    });

    it('linux.clipboard.read falls back from wl-paste to xclip, and hints when neither exists', async () => {
        const wayland = new FakeRunner('linux', [{ ok: 'from wayland' }]);
        expect(await new LinuxClipboardReadCapability(wayland).run()).toBe('from wayland');
        expect(wayland.calls[0].argv[0]).toBe('wl-paste');

        const x11 = new FakeRunner('linux', [{ err: { code: 'CMD_MISSING' } }, { ok: 'from x11' }]);
        expect(await new LinuxClipboardReadCapability(x11).run()).toBe('from x11');
        expect(x11.calls[1].argv[0]).toBe('xclip');

        const bare = new FakeRunner('linux', [{ err: { code: 'CMD_MISSING' } }]);
        expect(await new LinuxClipboardReadCapability(bare).run()).toContain('wl-clipboard');
    });

    it('linux.files.reveal opens the CONTAINING folder for a file, the folder itself otherwise', async () => {
        const shell = new FakeRunner('linux');
        await new LinuxFilesRevealCapability(shell).run('~/Downloads/report.pdf');
        expect(shell.calls[0].argv[0]).toBe('xdg-open');
        expect(shell.calls[0].argv[1]).toBe(`${os.homedir()}/Downloads`);
        await new LinuxFilesRevealCapability(shell).run('~/Downloads');
        expect(shell.calls[1].argv[1]).toBe(`${os.homedir()}/Downloads`);
    });

    it('capabilities refuse on the wrong platform without touching the runner', async () => {
        const linuxShell = new FakeRunner('linux');
        expect(await new WinClipboardReadCapability(linuxShell).run()).toBe('This runs on Windows only.');
        expect(linuxShell.calls).toHaveLength(0);
        const winShell = new FakeRunner('win32');
        expect(await new LinuxNotifyCapability(winShell).run('hi')).toBe('This runs on Linux only.');
        expect(winShell.calls).toHaveLength(0);
    });

    it('platformCapabilities picks the right set per OS and stays empty on macOS', () => {
        expect(platformCapabilities(new FakeRunner('win32')).map(c => c.name)).toEqual([
            'win.frontApp', 'win.clipboard.read', 'win.explorer.reveal', 'win.app.open', 'win.url.open',
        ]);
        expect(platformCapabilities(new FakeRunner('linux')).map(c => c.name)).toEqual([
            'linux.frontApp', 'linux.clipboard.read', 'linux.files.reveal', 'linux.url.open', 'linux.notify.send',
        ]);
        expect(platformCapabilities(new FakeRunner('darwin'))).toEqual([]);
    });

    it('front-window perception: fixed scripts, honest fallbacks', async () => {
        const win = new FakeRunner('win32', [{ ok: 'Code|main.ts — quenderin' }]);
        const out = await new WinFrontWindowCapability(win).run();
        expect(out).toBe('The frontmost app is Code — "main.ts — quenderin".');
        // The whole PowerShell script is the fixed template — zero interpolation points.
        expect(win.calls[0].argv).toEqual(powershell(WinFrontWindowCapability.SCRIPT));
        expect(win.calls[0].env).toBeUndefined();

        const linux = new FakeRunner('linux', [{ ok: 'Firefox — quenderin.org' }]);
        const lout = await new LinuxFrontWindowCapability(linux).run();
        expect(lout).toBe('The frontmost window is "Firefox — quenderin.org".');
        expect(linux.calls[0].argv).toEqual(['xdotool', 'getactivewindow', 'getwindowname']);

        const wayland = new FakeRunner('linux', [{ err: { code: 'CMD_MISSING' } }]);
        expect(await new LinuxFrontWindowCapability(wayland).run()).toContain('xdotool');
    });

    it('tiers are declared honestly (perception reads, actions mutate)', () => {
        for (const p of ['win32', 'linux'] as const) {
            for (const cap of platformCapabilities(new FakeRunner(p))) {
                if (cap.blastRadius.kind === 'read') {
                    expect(cap.tier).toBe(1);
                } else {
                    expect(cap.tier).toBeGreaterThanOrEqual(2);
                }
            }
        }
    });
});

describe('the governed loop runs the platform library end to end', () => {
    class FakeLlm implements ChatCompleter {
        private i = 0;
        constructor(private readonly replies: string[]) { }
        async generalChat(): Promise<{ text: string }> {
            return { text: this.replies[Math.min(this.i++, this.replies.length - 1)] };
        }
    }

    it('a Linux "open the docs and tell me" task: approval gates the write, ledger records it', async () => {
        const shell = new FakeRunner('linux');
        const consent = new InMemoryConsentStore();
        platformCapabilities(shell).forEach(c => consent.setGranted(c.name, true));
        const approvals: string[] = [];
        const agent = createGovernedAgent({
            llm: new FakeLlm([
                '{"tool":"linux.url.open","input":"https://quenderin.org/help"}',
                '{"answer":"Opened the help page."}',
            ]),
            shell,
            consent,
            approve: async (p) => { approvals.push(p.summary); return true; },
        });
        const result = await agent.run('open the quenderin help page');
        expect(result.halt).toBe('answered');
        expect(approvals).toEqual(['Open https://quenderin.org/help in the browser.']);
        expect(shell.calls[0].argv).toEqual(['xdg-open', 'https://quenderin.org/help']);
        expect(agent.ledger.entries().some(e => e.capability === 'linux.url.open' && e.decision === 'allowed')).toBe(true);
    });

    it('a declined approval on Windows changes nothing', async () => {
        const shell = new FakeRunner('win32');
        const consent = new InMemoryConsentStore();
        platformCapabilities(shell).forEach(c => consent.setGranted(c.name, true));
        const agent = createGovernedAgent({
            llm: new FakeLlm([
                '{"tool":"win.app.open","input":"notepad"}',
                '{"answer":"Okay, I did not open it."}',
            ]),
            shell,
            consent,
            approve: async () => false,
        });
        const result = await agent.run('open notepad');
        expect(result.halt).toBe('answered');
        expect(shell.calls).toHaveLength(0);
        expect(agent.ledger.entries().some(e => e.decision === 'declined')).toBe(true);
    });
});
