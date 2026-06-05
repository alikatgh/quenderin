import { Request, Response, NextFunction } from 'express';
import logger from '../utils/logger.js';

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction): void {
    const method = _req.method;
    const url = _req.originalUrl ?? _req.url;
    const message = err instanceof Error ? err.message : String(err);
    const stack = err instanceof Error ? err.stack : undefined;

    // Log full error with request context — never leak details to the client
    logger.error(`[HTTP ${method} ${url}] Unhandled error: ${message}`);
    if (stack) logger.debug(stack);

    res.status(500).json({ error: 'Internal Server Error' });
}
