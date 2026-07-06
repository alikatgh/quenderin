import { describe, it, expect, vi } from 'vitest';
import type { Request, Response } from 'express';
import { errorHandler } from '../src/middlewares/errorHandler.js';

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
});
