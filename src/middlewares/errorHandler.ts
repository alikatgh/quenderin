import { Request, Response, NextFunction } from 'express';

export function errorHandler(err: unknown, req: Request, res: Response, next: NextFunction): void {
    void req;
    void next;
    // Log full error internally but never leak message/stack to the client
    console.error('Unhandled Error:', err);
    res.status(500).json({ error: 'Internal Server Error' });
}
