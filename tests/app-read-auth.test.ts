import { describe, it, expect } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';
import { localRequest } from './helpers/localHttp.js';

/**
 * Q-007: read-only GETs that return USER DATA (sessions, notes, agent memory, the diagnostics
 * probe) must require the per-launch token — leaving them open let any loopback process exfiltrate
 * conversations with a plain curl. Genuinely-public GETs (/health, /ready) stay open so readiness
 * checks work before the renderer has a token.
 */
describe('read-route auth (Q-007)', () => {
    async function withApp(fn: (base: string) => Promise<void>) {
        const app = createApp(
            undefined as never, undefined as never, undefined as never,
            undefined as never, undefined as never, 'secret-token',
        );
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try {
            await fn(`http://127.0.0.1:${port}`);
        } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
        }
    }

    it('rejects unauthenticated GETs to user-data routes with 401', async () => {
        await withApp(async (base) => {
            for (const path of ['/api/sessions', '/api/notes', '/api/memory/trajectories', '/diagnostics', '/api/metrics']) {
                const res = await localRequest(`${base}${path}`);
                expect(res.status, `${path} should require auth`).toBe(401);
            }
        });
    });

    it('accepts the same GETs when the token is supplied', async () => {
        await withApp(async (base) => {
            // The route handlers themselves may 200/404/500 depending on injected services (we pass
            // none) — the point is the auth gate does NOT 401 when the token is present.
            const res = await localRequest(`${base}/api/sessions`, { headers: { 'X-Auth-Token': 'secret-token' } });
            expect(res.status).not.toBe(401);
        });
    });

    it('leaves public probes open without a token', async () => {
        await withApp(async (base) => {
            for (const path of ['/health', '/ready']) {
                const res = await localRequest(`${base}${path}`);
                expect(res.status, `${path} should stay public`).not.toBe(401);
            }
        });
    });
});
