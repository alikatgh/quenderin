import fs from 'fs';
import os from 'os';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { MetricsService, AgentMetrics } from '../src/services/metrics.service.js';

/**
 * Q-285: appendMetrics read-modify-writes one JSON file. Two concurrent agent runs used to interleave
 * their read → push → write and lose records (last write wins). The write-chain serializes them.
 */
describe('MetricsService.appendMetrics — concurrent writes never lose records', () => {
    let dir: string;
    let file: string;
    let svc: MetricsService;

    beforeEach(() => {
        dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qmetrics-'));
        file = path.join(dir, 'telemetry.json');
        fs.writeFileSync(file, '[]');
        svc = new MetricsService();
        // Point it at the temp file (the constructor targets ~/.quenderin).
        (svc as unknown as { telemetryPath: string }).telemetryPath = file;
    });
    afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

    const metric = (i: number): AgentMetrics => ({
        id: `run-${i}`, goal_text: `goal ${i}`, success: true, total_steps: 1, duration_ms: 1, total_retries: 0, timestamp: 'x',
    });

    it('keeps all records when 25 writes fire at once', async () => {
        const N = 25;
        await Promise.all(Array.from({ length: N }, (_, i) => svc.appendMetrics(metric(i))));
        const records: AgentMetrics[] = JSON.parse(fs.readFileSync(file, 'utf8'));
        expect(records).toHaveLength(N);                              // none lost to the race
        expect(new Set(records.map(r => r.id)).size).toBe(N);        // and all distinct
    });
});
