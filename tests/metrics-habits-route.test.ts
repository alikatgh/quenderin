import { describe, it, expect } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';
import type { MetricsService } from '../src/services/metrics.service.js';

/**
 * Q-599: MetricsService.getHabits() (the background daemon's autonomous-run telemetry) existed but had no
 * REST route, so it was invisible to any client. /api/metrics/habits now exposes it, under the token gate.
 */
describe('/api/metrics/habits (Q-599)', () => {
    const stubMetrics = {
        getMetrics: async () => ({}),
        getHabits: async () => [{ action: 'daemon_run', timestamp: '2026-07-06T00:00:00.000Z' }],
    } as unknown as MetricsService;

    async function withApp(metrics: MetricsService | undefined, fn: (base: string) => Promise<void>) {
        const app = createApp(metrics as never, undefined as never, undefined as never, undefined as never, undefined as never, 'secret-token');
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try {
            await fn(`http://127.0.0.1:${port}`);
        } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
        }
    }

    it('requires the auth token (inherits the /api/metrics prefix gate)', async () => {
        await withApp(stubMetrics, async (base) => {
            const res = await fetch(`${base}/api/metrics/habits`);
            expect(res.status).toBe(401);
        });
    });

    it('returns the habits payload when authorized', async () => {
        await withApp(stubMetrics, async (base) => {
            const res = await fetch(`${base}/api/metrics/habits`, { headers: { 'X-Auth-Token': 'secret-token' } });
            expect(res.status).toBe(200);
            const body = await res.json();
            expect(Array.isArray(body.habits)).toBe(true);
            expect(body.habits[0].action).toBe('daemon_run');
        });
    });
});
