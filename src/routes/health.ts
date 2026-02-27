import { Router } from 'express';
import path from 'path';
import fs from 'fs';
import { LLM_MODEL_PATH } from '../constants.js';

const router = Router();

router.get('/health', (req, res) => {
    const activeModel = path.basename(LLM_MODEL_PATH);
    const isBrainInstalled = fs.existsSync(LLM_MODEL_PATH);
    res.status(200).json({ status: 'OK', uptime: process.uptime(), activeModel, isBrainInstalled });
});

export default router;
