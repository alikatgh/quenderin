import { describe, it, expect, vi } from 'vitest';
import type { Request, Response } from 'express';
import { errorHandler } from '../src/middlewares/errorHandler.js';
import logger from '../src/utils/logger.js';

/**
 * Q-423: the cors() origin callback rejects a disallowed origin with `new Error('CORS: …')`, which
 * reached the generic errorHandler and became a 500 — a client-origin POLICY denial misreported as a
 * server crash (pollutes monitoring). It now maps CORS errors to 403 while everything else stays 500.
 */
function mockRes() {
    return { status: vi.fn().mockReturnThis(), json: vi.fn().mockReturnThis() } as unknown as Response;
}
const req = { method: 'GET', url: '/x', originalUrl: '/x' } as unknown as Request;

describe('errorHandler status mapping (Q-423)', () => {
    it('maps a CORS-origin rejection to 403, not 500', () => {
        const res = mockRes();
        errorHandler(new Error("CORS: origin 'https://evil.example' is not allowed"), req, res, vi.fn());
        expect(res.status).toHaveBeenCalledWith(403);
        expect(res.status).not.toHaveBeenCalledWith(500);
    });

    it('keeps a genuine unhandled error as 500', () => {
        const res = mockRes();
        errorHandler(new Error('database exploded'), req, res, vi.fn());
        expect(res.status).toHaveBeenCalledWith(500);
    });

    it('redacts ?token= from the logged URL (Q-355)', () => {
        const errorSpy = vi.spyOn(logger, 'error').mockImplementation(() => undefined as unknown as void);
        const res = mockRes();
        const tokened = { method: 'GET', url: '/api/x?token=SUPERSECRET&y=1', originalUrl: '/api/x?token=SUPERSECRET&y=1' } as unknown as Request;
        errorHandler(new Error('boom'), tokened, res, vi.fn());
        const logged = errorSpy.mock.calls.map(c => String(c[0])).join(' ');
        expect(logged).not.toContain('SUPERSECRET');
        expect(logged).toContain('<redacted>');
        errorSpy.mockRestore();
    });
});
