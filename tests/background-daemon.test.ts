import { describe, it, expect, beforeAll } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { PNG } from 'pngjs';
import { BackgroundDaemonService } from '../src/services/backgroundDaemon.service.js';
import type { IDeviceProvider } from '../src/types/index.js';
import type { MetricsService } from '../src/services/metrics.service.js';

/**
 * r37/r50 backlog #6: the daemon's core is the visual-diff math that decides whether a habit-log
 * row is written at all — post-redesign (no LLM, no fake vision) it is pure pixel work and fully
 * testable with generated PNGs. The poll loop itself is a timer wrapper around this and stays
 * covered by the honest-error/idle-backoff code paths it calls; spinning real timers in a unit
 * test buys nothing.
 */

function pngFile(dir: string, name: string, width: number, height: number, rgba: [number, number, number, number], mutate?: (png: PNG) => void): string {
    const png = new PNG({ width, height });
    for (let i = 0; i < width * height; i++) {
        png.data[i * 4] = rgba[0];
        png.data[i * 4 + 1] = rgba[1];
        png.data[i * 4 + 2] = rgba[2];
        png.data[i * 4 + 3] = rgba[3];
    }
    mutate?.(png);
    const p = path.join(dir, name);
    fs.writeFileSync(p, PNG.sync.write(png));
    return p;
}

function makeDaemon() {
    const fakeProvider = { getScreenContext: async () => ({ screenshotPath: '' }) } as unknown as IDeviceProvider;
    const fakeMetrics = { appendHabitLog: async () => { /* recorded elsewhere */ } } as unknown as MetricsService;
    const daemon = new BackgroundDaemonService(fakeProvider, fakeMetrics);
    // The diff engine is private by design; the tests exercise it directly — it IS the unit.
    const diff = (p: string): Promise<{ diffRatio: number }> =>
        (daemon as unknown as { calculateVisualDiff(p: string): Promise<{ diffRatio: number }> }).calculateVisualDiff(p);
    return { daemon, diff };
}

describe('BackgroundDaemon visual diff', () => {
    let dir: string;
    beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qdaemon-')); });

    it('first frame is a 100% diff (nothing to compare against)', async () => {
        const { diff } = makeDaemon();
        const first = pngFile(dir, 'a1.png', 10, 10, [255, 0, 0, 255]);
        expect((await diff(first)).diffRatio).toBe(1.0);
    });

    it('an identical frame diffs to ~0 (no habit row for a static screen)', async () => {
        const { diff } = makeDaemon();
        await diff(pngFile(dir, 'b1.png', 10, 10, [255, 0, 0, 255]));
        const again = pngFile(dir, 'b2.png', 10, 10, [255, 0, 0, 255]);
        expect((await diff(again)).diffRatio).toBe(0);
    });

    it('a half-changed frame reports roughly half the pixels', async () => {
        const { diff } = makeDaemon();
        await diff(pngFile(dir, 'c1.png', 10, 10, [255, 0, 0, 255]));
        const half = pngFile(dir, 'c2.png', 10, 10, [255, 0, 0, 255], (png) => {
            for (let i = 0; i < 50; i++) { // top half of a 10×10 → blue
                png.data[i * 4] = 0; png.data[i * 4 + 2] = 255;
            }
        });
        const { diffRatio } = await diff(half);
        expect(diffRatio).toBeGreaterThan(0.4);
        expect(diffRatio).toBeLessThan(0.6);
    });

    it('a dimension change (rotation / other monitor) resets the baseline as a full diff', async () => {
        const { diff } = makeDaemon();
        await diff(pngFile(dir, 'd1.png', 10, 10, [255, 0, 0, 255]));
        const rotated = pngFile(dir, 'd2.png', 20, 5, [255, 0, 0, 255]);
        expect((await diff(rotated)).diffRatio).toBe(1.0);
        // ...and the NEW dimensions become the baseline: an identical 20×5 frame is now ~0.
        const again = pngFile(dir, 'd3.png', 20, 5, [255, 0, 0, 255]);
        expect((await diff(again)).diffRatio).toBe(0);
    });

    it('an unreadable path degrades to diff 0 and emits an error (never throws into the loop)', async () => {
        const { daemon, diff } = makeDaemon();
        let emitted = '';
        daemon.on('error', (m: string) => { emitted = m; });
        const { diffRatio } = await diff(path.join(dir, 'does-not-exist.png'));
        expect(diffRatio).toBe(0);
        expect(emitted).toContain('Failed to calculate visual diff');
    });
});
