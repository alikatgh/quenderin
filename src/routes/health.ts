import { Router } from 'express';
import fs from 'fs';
import os from 'os';
import { MODEL_CATALOG, modelPath, getHardwareRecommendation } from '../constants.js';

const router = Router();

/**
 * Shared LlmService reference — set via setLlmService() from server.ts.
 * This avoids circular imports while letting /health reflect the real loaded model.
 */
let llmServiceRef: { getActiveModelLabel: () => string } | null = null;

export function setHealthLlmService(service: { getActiveModelLabel: () => string }) {
    llmServiceRef = service;
}

router.get('/health', (_req, res) => {
    const activeModel = llmServiceRef?.getActiveModelLabel() ?? 'not loaded';
    const isBrainInstalled = MODEL_CATALOG.some(m => fs.existsSync(modelPath(m.id)));
    const recommendation = getHardwareRecommendation();
    res.status(200).json({
        status: 'OK',
        uptime: process.uptime(),
        activeModel,
        isBrainInstalled,
        totalRamGb: +(os.totalmem() / (1024 ** 3)).toFixed(1),
        freeRamGb: +(os.freemem() / (1024 ** 3)).toFixed(1),
        recommendedMaxParams: recommendation.maxParams,
    });
});

export default router;
