import { describe, it, expect } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';

/**
 * The security-headers middleware runs before all routes, so even an unmatched (404) request carries
 * the headers. Regression for the deep-hunt: the per-launch auth token is delivered in the opened URL
 * (`?token=`), so a `Referrer-Policy: no-referrer` is set to keep it from leaking via the Referer.
 */
describe('security headers', () => {
    it('sets Referrer-Policy: no-referrer and a CSP on every response', async () => {
        const app = createApp(
            undefined as never, undefined as never, undefined as never,
            undefined as never, undefined as never, 'test-token',
        );
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try {
            const res = await fetch(`http://127.0.0.1:${port}/this-route-does-not-exist`);
            // Our middleware runs before all routes, so the Referrer-Policy is present even on a 404.
            // (The CSP on a 404 is Express finalhandler's own `default-src 'none'`, not ours, so we
            // don't assert the CSP value here — the middleware ordering is what matters.)
            expect(res.headers.get('referrer-policy')).toBe('no-referrer');
        } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
        }
    });

    it('sets the hardened CSP directives on a served route (Q-561)', async () => {
        const app = createApp(
            undefined as never, undefined as never, undefined as never,
            undefined as never, undefined as never, 'test-token',
        );
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try {
            // /health is a public 200 route, so OUR middleware's CSP survives (a 404 gets Express's own).
            const res = await fetch(`http://127.0.0.1:${port}/health`);
            const csp = res.headers.get('content-security-policy') ?? '';
            expect(csp).toContain("frame-ancestors 'none'");
            expect(csp).toContain("object-src 'none'");
            expect(csp).toContain("base-uri 'self'");
        } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
        }
    });
});
