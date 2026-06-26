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
