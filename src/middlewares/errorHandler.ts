import { Request, Response, NextFunction } from 'express';

export function errorHandler(err: any, req: Request, res: Response, _next: NextFunction) {
    // Log full error internally but never leak message/stack to the client
    console.error('Unhandled Error:', err);
    res.status(500).json({ error: 'Internal Server Error' });
}
