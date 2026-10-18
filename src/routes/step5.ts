import { Router } from 'express';
import { Step5Client } from '../services/step5.js';

export function step5Routes(client = new Step5Client()): Router {
    const router = Router();
    router.post('/cancel', (_req, res) => { client.cancel(); res.json({ cancelled: true }); });
    for (const action of ['check', 'answer'] as const) router.post(`/${action}`, async (req, res) => {
        const controller = new AbortController();
        const close = () => { if (!res.writableEnded) controller.abort(); };
        res.on('close', close);
        try {
            if (req.body?.consent !== true) throw new Error('Confirm that this conversation may be sent to your chosen CUDA host.');
            const result = action === 'check' ? await client.check(req.body.endpoint, controller.signal) : await client.answer(req.body.endpoint, req.body.messages, controller.signal);
            if (!controller.signal.aborted) res.json(result ?? { ready: true });
        } catch (error) {
            if (!controller.signal.aborted && !res.headersSent) res.status(400).json({ error: error instanceof Error ? error.message : 'Step 5 operation failed.' });
        } finally { res.off('close', close); }
    });
    return router;
}
