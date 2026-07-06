import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

/**
 * Q-505/Q-470: availableMemBytes() ran a BLOCKING execSync('vm_stat') (macOS) / /proc read on every
 * call, and it's called from hot paths (the LLM memory-pressure monitor, /health polling, every tool
 * handler) — tens of ms of event-loop stall apiece. It now memoizes for MEM_CACHE_TTL_MS. These tests
 * pin that rapid calls share ONE probe (the fix) and that the probe refreshes after the TTL.
 */
const execSyncMock = vi.fn();
vi.mock('child_process', () => ({ execSync: (...args: unknown[]) => execSyncMock(...args) }));

const { availableMemBytes, __resetMemCacheForTests, MEM_CACHE_TTL_MS } = await import('../src/utils/memory.js');

const CANNED_VMSTAT = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              100000.
Pages active:                             80000.
Pages inactive:                           50000.
Pages speculative:                        10000.
Pages purgeable:                           5000.
`;

describe('availableMemBytes caching (Q-505)', () => {
    beforeEach(() => {
        execSyncMock.mockReset();
        execSyncMock.mockReturnValue(CANNED_VMSTAT);
        __resetMemCacheForTests();
    });
    afterEach(() => vi.useRealTimers());

    // The rigorous proof runs where the vm_stat/execSync path is active (this dev machine + macOS CI).
    it.runIf(process.platform === 'darwin')('probes vm_stat ONCE for rapid successive calls', () => {
        vi.useFakeTimers();
        const a = availableMemBytes();
        const b = availableMemBytes();
        const c = availableMemBytes();
        expect(a).toBeGreaterThan(0);
        expect(a).toBe(b);
        expect(b).toBe(c);
        expect(execSyncMock).toHaveBeenCalledTimes(1);   // the cache spared two blocking probes
    });

    it.runIf(process.platform === 'darwin')('re-probes once the TTL has elapsed', () => {
        vi.useFakeTimers();
        availableMemBytes();
        expect(execSyncMock).toHaveBeenCalledTimes(1);
        vi.advanceTimersByTime(MEM_CACHE_TTL_MS + 10);
        availableMemBytes();
        expect(execSyncMock).toHaveBeenCalledTimes(2);
    });

    it('returns an identical cached value within the TTL (platform-agnostic)', () => {
        vi.useFakeTimers();
        const first = availableMemBytes();
        expect(first).toBeGreaterThan(0);
        expect(availableMemBytes()).toBe(first);   // no re-probe within the window → identical
    });
});
