import { describe, it, expect } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';
import type { AgentService } from '../src/services/agent.service.js';

/**
 * Q-549 (governance Step 1): GET /api/agent/ledger exposes the device agent's action flight recorder.
 * It returns user data (what was tapped, for which goal), so it must require the per-launch token.
 */
describe('/api/agent/ledger (Q-549)', () => {
    const stubAgent = {
        actionLedger: {
            entries: () => [{ timestampMs: 1, capability: 'device.click', tier: 0, input: 'id=1', decision: 'allowed', goal: 'open settings' }],
        },
        // pause/resume exist on the real service (the intervene/resume routes reference them) but aren't hit here.
        pause: () => { /* noop */ },
        resume: () => { /* noop */ },
    } as unknown as AgentService;

    async function withApp(fn: (base: string) => Promise<void>) {
        const app = createApp(undefined as never, stubAgent as never, undefined as never, undefined as never, undefined as never, 'secret-token');
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try {
            await fn(`http://127.0.0.1:${port}`);
        } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
        }
    }

    it('requires the auth token', async () => {
        await withApp(async (base) => {
            const res = await fetch(`${base}/api/agent/ledger`);
            expect(res.status).toBe(401);
        });
    });

    it('returns the ledger entries when authorized', async () => {
        await withApp(async (base) => {
            const res = await fetch(`${base}/api/agent/ledger`, { headers: { 'X-Auth-Token': 'secret-token' } });
            expect(res.status).toBe(200);
            const body = await res.json();
            expect(Array.isArray(body.ledger)).toBe(true);
            expect(body.ledger[0]).toMatchObject({ capability: 'device.click', decision: 'allowed', goal: 'open settings' });
        });
    });
});
