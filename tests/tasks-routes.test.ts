import { describe, it, expect } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';

/**
 * The governed Tasks routes: the ledger (per-task action history — user data, token-gated) and
 * the capability catalog (discovery — what the agent can do on this machine).
 */
describe('/api/tasks/* (governed agent surface)', () => {
    async function withApp(fn: (base: string) => Promise<void>) {
        const app = createApp(undefined as never, undefined as never, undefined as never, undefined as never, undefined as never, 'secret-token');
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try {
            await fn(`http://127.0.0.1:${port}`);
        } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
        }
    }

    it('the ledger requires the auth token (it is the user\'s action history)', async () => {
        await withApp(async (base) => {
            expect((await fetch(`${base}/api/tasks/ledger`)).status).toBe(401);
            expect((await fetch(`${base}/api/tasks/capabilities`)).status).toBe(401);
        });
    });

    it('returns ledger entries (bounded) when authorized', async () => {
        await withApp(async (base) => {
            const res = await fetch(`${base}/api/tasks/ledger`, { headers: { 'X-Auth-Token': 'secret-token' } });
            expect(res.status).toBe(200);
            const body = await res.json();
            expect(Array.isArray(body.entries)).toBe(true);
            expect(body.entries.length).toBeLessThanOrEqual(200);
        });
    });

    it('lists this machine\'s capabilities with tier/mutates metadata', async () => {
        await withApp(async (base) => {
            const res = await fetch(`${base}/api/tasks/capabilities`, { headers: { 'X-Auth-Token': 'secret-token' } });
            expect(res.status).toBe(200);
            const body = await res.json() as { capabilities: Array<{ name: string; purpose: string; tier: number; mutates: boolean; needsWorkspace: boolean }> };
            expect(body.capabilities.length).toBeGreaterThan(0);
            // fs.* always list (with the needs-a-workspace flag); OS sets vary by host platform.
            const fsMove = body.capabilities.find(c => c.name === 'fs.move');
            expect(fsMove).toBeDefined();
            expect(fsMove!.needsWorkspace).toBe(true);
            expect(fsMove!.mutates).toBe(true);
            for (const c of body.capabilities) {
                expect(typeof c.name).toBe('string');
                expect(typeof c.purpose).toBe('string');
                expect(typeof c.tier).toBe('number');
            }
        });
    });
});
