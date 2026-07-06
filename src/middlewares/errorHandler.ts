import { Request, Response, NextFunction } from 'express';
import logger from '../utils/logger.js';

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction): void {
    const method = _req.method;
    const url = _req.originalUrl ?? _req.url;
    const message = err instanceof Error ? err.message : String(err);
    const stack = err instanceof Error ? err.stack : undefined;

    // Q-423: a CORS-origin rejection is a client POLICY denial, not a server fault. Report it as 403
    // (Forbidden) instead of 500 — a 500 misrepresents a refused cross-origin request as a crash, which
    // pollutes error monitoring and misleads anyone reading the logs. The cors() origin callback rejects
    // with `new Error('CORS: …')`, so match that prefix.
    if (message.startsWith('CORS:')) {
        logger.debug(`[HTTP ${method} ${url}] CORS rejected: ${message}`);
        res.status(403).json({ error: 'Origin not allowed.' });
        return;
    }

    // Log full error with request context — never leak details to the client
    logger.error(`[HTTP ${method} ${url}] Unhandled error: ${message}`);
    if (stack) logger.debug(stack);

    res.status(500).json({ error: 'Internal Server Error' });
}
