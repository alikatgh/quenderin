import { describe, it, expect, vi } from 'vitest';
import { EventEmitter } from 'events';

/**
 * Regression: `spawnAdb` had no `proc.on('error')` handler. When adb isn't installed (ENOENT —
 * platform-tools is a separate install), Node emits an 'error' event that, unhandled, it re-throws
 * as an uncaught exception; and 'close' never fires, so the promise hung until the misleading
 * ADB_TIMEOUT. The handler now rejects promptly with code ADB_MISSING (the code the websocket +
 * background daemon already route to a user-facing "set up Android" prompt).
 */
function makeSpawnErrorProc(code: string) {
    const proc = new EventEmitter() as EventEmitter & {
        stdout: EventEmitter; stderr: EventEmitter; kill: () => void;
    };
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    proc.kill = vi.fn();
    // Node emits the spawn failure asynchronously, like a real ENOENT.
    setTimeout(() => {
        const err = new Error(`spawn adb ${code}`) as Error & { code?: string };
        err.code = code;
        proc.emit('error', err);
    }, 0);
    return proc;
}

const spawnMock = vi.fn();
vi.mock('child_process', () => ({ spawn: (...args: unknown[]) => spawnMock(...args) }));

describe('AndroidProvider.spawnAdb — spawn-failure handling (no hang/crash when adb is missing)', () => {
    it('rejects with ADB_MISSING (not a hang or a misleading timeout) when adb is not installed', async () => {
        spawnMock.mockImplementation(() => makeSpawnErrorProc('ENOENT'));
        const { AndroidProvider } = await import('../src/services/providers/android.provider.js');
        const provider = new AndroidProvider();
        await expect(provider.click(10, 20)).rejects.toMatchObject({ code: 'ADB_MISSING' });
    });

    it('also handles a non-ENOENT spawn error (e.g. EACCES) without hanging', async () => {
        spawnMock.mockImplementation(() => makeSpawnErrorProc('EACCES'));
        const { AndroidProvider } = await import('../src/services/providers/android.provider.js');
        const provider = new AndroidProvider();
        await expect(provider.click(1, 2)).rejects.toMatchObject({ code: 'ADB_MISSING' });
    });
});

describe('splitLiteralPercentS — a literal "%s" is never typed as a space (r-uc #2)', () => {
    it('splits between the % and the s so they cannot form the substitution', async () => {
        const { splitLiteralPercentS } = await import('../src/services/providers/android.provider.js');
        expect(splitLiteralPercentS('increase%special')).toEqual(['increase%', 'special']);
        expect(splitLiteralPercentS('%s')).toEqual(['%', 's']);
        expect(splitLiteralPercentS('a%sb%sc')).toEqual(['a%', 'sb%', 'sc']);
    });

    it('leaves ordinary text (no literal %s) as a single segment', async () => {
        const { splitLiteralPercentS } = await import('../src/services/providers/android.provider.js');
        expect(splitLiteralPercentS('hello world')).toEqual(['hello world']);
        expect(splitLiteralPercentS('50% off')).toEqual(['50% off']); // % not followed by s
        expect(splitLiteralPercentS('')).toEqual([]);
    });

    it('concatenating the segments reconstructs the original exactly', async () => {
        const { splitLiteralPercentS } = await import('../src/services/providers/android.provider.js');
        for (const s of ['%s', 'a%sb', 'x%s%sy', 'no percent', '%', 's%', 'trailing%']) {
            expect(splitLiteralPercentS(s).join('')).toBe(s);
        }
    });
});

describe('AndroidProvider.pressKey — unknown keys never fall back to ENTER (r-uc #9)', () => {
    it('refuses an unknown key instead of pressing ENTER, and sends no keyevent', async () => {
        const { AndroidProvider } = await import('../src/services/providers/android.provider.js');
        const provider = new AndroidProvider();
        spawnMock.mockClear();
        await expect(provider.pressKey('definitely-not-a-key')).rejects.toThrow(/Unsupported key/);
        expect(spawnMock).not.toHaveBeenCalled();
    });
});
