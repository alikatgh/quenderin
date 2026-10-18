import type { Express, Request, Response } from 'express';
import type { HyMemoryWorkflow } from '../services/hyMemory.js';

/** Nested under the already protected /api/memory read prefix; mutations use normal API auth. */
export function registerHyMemoryRoutes(app: Express, workflow: HyMemoryWorkflow): void {
    const exact = (body: unknown, keys: string[]): Record<string, unknown> => {
        if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).length !== keys.length || !keys.every(key => Object.hasOwn(body, key))) throw new Error('Invalid Hy-Memory request.');
        return body as Record<string, unknown>;
    };
    const action = (work: (request: Request) => Promise<unknown>) => async (request: Request, response: Response) => {
        const cancel = () => { if (!response.writableFinished) workflow.cancel(); };
        request.on('aborted', cancel); response.on('close', cancel);
        try { response.json(await work(request)); }
        catch (error) { if (!response.destroyed) response.status(400).json({ error: (error instanceof Error ? error.message : 'Hy-Memory operation failed.').slice(0, 2048) }); }
        finally { request.removeListener('aborted', cancel); response.removeListener('close', cancel); }
    };
    app.get('/api/memory/hy/status', action(() => workflow.status()));
    app.post('/api/memory/hy/install', action(async request => { exact(request.body ?? {}, []); await workflow.install(); return workflow.status(); }));
    app.post('/api/memory/hy/propose', action(request => {
        const body = exact(request.body, ['conversation']); if (typeof body.conversation !== 'string') throw new Error('Select a bounded conversation.'); return workflow.propose(body.conversation);
    }));
    app.post('/api/memory/hy/approve', action(request => { const body = exact(request.body, ['batchId', 'proposalIds']); return workflow.approve(body.batchId, body.proposalIds); }));
    app.post('/api/memory/hy/cancel', action(async request => { exact(request.body ?? {}, []); workflow.cancel(); return { cancelling: true }; }));
}
