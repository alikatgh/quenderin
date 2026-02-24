import { Router } from 'express';
import path from 'path';

const router = Router();

router.get('/health', (req, res) => {
    const rawPath = process.env.LLM_MODEL_PATH || 'llama-3-instruct-8b.Q4_K_M.gguf';
    const activeModel = path.basename(rawPath);
    res.status(200).json({ status: 'OK', uptime: process.uptime(), activeModel });
});

export default router;
