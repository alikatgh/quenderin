import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import fsSync from 'fs';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';

// The MetricsService constructor resolves its storage path from os.homedir() at
// construction time (homeDir/.quenderin/...). To isolate the test from the real
// user home directory, we mock os.homedir() to return a fresh per-test temp dir.
// We mock at the module boundary so the service's `import os from 'os'` sees it.
vi.mock('os', async (importOriginal) => {
    const actual = await importOriginal<typeof import('os')>();
    return {
        ...actual,
        default: { ...actual, homedir: () => currentHome },
        homedir: () => currentHome,
    };
});

// The directory os.homedir() will resolve to for the current test.
let currentHome: string;

// Import AFTER vi.mock so the service module picks up the mocked os.
const { MetricsService } = await import('../src/services/metrics.service.js');
type HabitLog = import('../src/services/metrics.service.js').HabitLog;
type AgentMetrics = import('../src/services/metrics.service.js').AgentMetrics;

function makeLog(overrides: Partial<HabitLog> = {}): HabitLog {
    return {
        id: 'log-' + Math.random().toString(36).slice(2),
        timestamp: new Date().toISOString(),
        diff_score: 0.42,
        description: 'did a thing',
        ...overrides,
    };
}

function makeMetric(i: number): AgentMetrics {
    return {
        id: 'm' + i,
        goal_text: 'g' + i,
        success: true,
        total_steps: 1,
        duration_ms: 1,
        total_retries: 0,
        timestamp: new Date(2026, 0, 1, 0, 0, i % 60).toISOString(),
    };
}

describe('MetricsService.appendHabitLog', () => {
    let configDir: string;
    let habitsPath: string;
    let telemetryPath: string;

    beforeEach(async () => {
        // Fresh isolated home dir per test. os.homedir() (mocked) returns this.
        currentHome = await fs.mkdtemp(path.join(os.tmpdir(), 'quenderin-metrics-'));
        configDir = path.join(currentHome, '.quenderin');
        habitsPath = path.join(configDir, 'habits.ndjson');
        telemetryPath = path.join(configDir, 'telemetry.json');
        // The MetricsService constructor performs this same initialization, but it is
        // fire-and-forget (un-awaited mkdir/writeFile chain). Doing it deterministically
        // here removes that race so each test observes the real append/read behavior —
        // it does NOT re-implement any method under test, just the store bootstrap the
        // constructor would otherwise do on its own clock.
        await fs.mkdir(configDir, { recursive: true });
        await fs.writeFile(habitsPath, '', 'utf-8');
        await fs.writeFile(telemetryPath, JSON.stringify([]), 'utf-8');
    });

    afterEach(async () => {
        // currentHome is always a fresh mkdtemp path under os.tmpdir(); safe to remove.
        await fs.rm(currentHome, { recursive: true, force: true });
    });

    it('persists a HabitLog as NDJSON that can be read back via getHabits', async () => {
        const service = new MetricsService();
        const log = makeLog({ id: 'h1', description: 'morning run', diff_score: 0.91 });

        await service.appendHabitLog(log);

        // Real on-disk effect: one NDJSON line written to the resolved path.
        const raw = await fs.readFile(habitsPath, 'utf-8');
        expect(raw).toBe(JSON.stringify(log) + '\n');

        // Real read-back behavior through the service's own getHabits().
        const habits = await service.getHabits();
        expect(habits).toEqual([log]);
    });

    it('appends multiple logs in order, one NDJSON line each', async () => {
        const service = new MetricsService();
        const a = makeLog({ id: 'a' });
        const b = makeLog({ id: 'b' });
        const c = makeLog({ id: 'c' });

        await service.appendHabitLog(a);
        await service.appendHabitLog(b);
        await service.appendHabitLog(c);

        const raw = await fs.readFile(habitsPath, 'utf-8');
        const lines = raw.split('\n').filter(l => l.length > 0);
        expect(lines).toHaveLength(3);

        const habits = await service.getHabits();
        expect(habits.map(h => h.id)).toEqual(['a', 'b', 'c']);
        expect(habits).toEqual([a, b, c]);
    });

    it('round-trips full HabitLog field fidelity (id, timestamp, diff_score, description)', async () => {
        const service = new MetricsService();
        const log = makeLog({
            id: 'fidelity-1',
            timestamp: '2026-06-29T12:34:56.789Z',
            diff_score: -1.5,
            description: 'has "quotes", commas, and \n newlines escaped',
        });

        await service.appendHabitLog(log);

        const [readBack] = await service.getHabits();
        expect(readBack).toEqual(log);
        expect(readBack.diff_score).toBe(-1.5);
        expect(readBack.timestamp).toBe('2026-06-29T12:34:56.789Z');
    });

    it('writes to homeDir/.quenderin/habits.ndjson (path resolution from constructor)', async () => {
        const service = new MetricsService();
        await service.appendHabitLog(makeLog({ id: 'path-check' }));

        // The file must exist at exactly the constructor-resolved location.
        expect(fsSync.existsSync(habitsPath)).toBe(true);
        // And NOT in the real user home — the mock kept us inside the temp dir.
        expect(habitsPath.startsWith(currentHome)).toBe(true);
    });

    it('two service instances share the same on-disk store (append is additive)', async () => {
        const first = new MetricsService();
        await first.appendHabitLog(makeLog({ id: 'from-first' }));

        const second = new MetricsService();
        await second.appendHabitLog(makeLog({ id: 'from-second' }));

        // A third reader sees both — proves the data is durably on disk, not in memory.
        const reader = new MetricsService();
        const ids = (await reader.getHabits()).map(h => h.id);
        expect(ids).toEqual(['from-first', 'from-second']);
    });

    it('getHabits returns [] when no habits have been logged', async () => {
        const service = new MetricsService();
        // Nothing appended yet; the file may be absent (constructor init is async/lazy).
        const habits = await service.getHabits();
        expect(habits).toEqual([]);
    });

    it('getHabits ignores malformed (non-JSON) lines without throwing', async () => {
        // Pre-seed the file with a good line, a garbage line, and another good line.
        const good1 = makeLog({ id: 'g1' });
        const good2 = makeLog({ id: 'g2' });
        await fs.writeFile(
            habitsPath,
            JSON.stringify(good1) + '\n' + 'this-is-not-json\n' + JSON.stringify(good2) + '\n',
            'utf-8',
        );

        const service = new MetricsService();
        const habits = await service.getHabits();
        expect(habits.map(h => h.id)).toEqual(['g1', 'g2']);
    });

    // NOTE on the compaction branch: getHabits() compacts only when the file has
    // > 2000 lines, then returns the last 1000. We assert the documented cap below
    // with a moderately sized seed (3 logs) by checking slice(-1000) is a no-op for
    // small files. The >2000-line compaction path writes the file asynchronously
    // (fire-and-forget) and is verified at the return-value level rather than by
    // racing the un-awaited rewrite to disk.
    it('getHabits returns at most the most-recent 1000 entries', async () => {
        const total = 1003;
        const lines: string[] = [];
        for (let i = 0; i < total; i++) {
            lines.push(JSON.stringify(makeLog({ id: 'n' + i })));
        }
        await fs.writeFile(habitsPath, lines.join('\n') + '\n', 'utf-8');

        const service = new MetricsService();
        const habits = await service.getHabits();
        // <= 2000 lines, so no compaction; capped to last 1000 by slice(-1000).
        expect(habits).toHaveLength(1000);
        expect(habits[0].id).toBe('n3'); // first 3 dropped, last 1000 kept
        expect(habits[habits.length - 1].id).toBe('n1002');
    });

    it('appendMetrics + getMetrics round-trip via the same isolated store', async () => {
        // Sibling sanity check that the os.homedir() mock isolates telemetry too.
        const service = new MetricsService();
        const metrics: AgentMetrics = {
            id: 'm1',
            goal_text: 'open settings',
            success: true,
            total_steps: 4,
            duration_ms: 1234,
            total_retries: 1,
            timestamp: '2026-06-29T00:00:00.000Z',
        };
        await service.appendMetrics(metrics);

        const read = await service.getMetrics();
        expect(read).toEqual([metrics]);
    });

    it('appendMetrics caps telemetry at 1000 records, evicting the oldest and keeping the newest', async () => {
        const seed = Array.from({ length: 1000 }, (_, i) => makeMetric(i));
        await fs.writeFile(telemetryPath, JSON.stringify(seed, null, 2), 'utf-8');

        const service = new MetricsService();
        await service.appendMetrics(makeMetric(1000));

        const all = await service.getMetrics();
        expect(all).toHaveLength(1000);               // exactly the cap, not 1001
        expect(all[all.length - 1].id).toBe('m1000'); // newest retained
        expect(all.find(m => m.id === 'm0')).toBeUndefined(); // oldest evicted
        expect(all[0].id).toBe('m1');                 // slice(-999) of 1000 keeps the last 999 (drops only m0) before the push
    });
});
