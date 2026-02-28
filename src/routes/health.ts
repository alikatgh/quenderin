import { Router } from 'express';
import fs from 'fs';
import os from 'os';
import { MODEL_CATALOG, modelPath, getHardwareRecommendation } from '../constants.js';
import { availableMemBytes } from '../utils/memory.js';
import { getHardwareProfile } from '../utils/hardware.js';

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
    const hw = getHardwareProfile();

    // Hardware-adaptive context options for the settings UI
    const contextOptions = hw.tier === 'embedded'
        ? [256, 512, 1024]
        : hw.tier === 'constrained'
        ? [512, 1024, 2048]
        : hw.tier === 'powerful'
        ? [2048, 4096, 8192]
        : [1024, 2048, 4096]; // standard

    // Best default model to recommend for download based on hardware
    const recommendedModelId = hw.totalRamGb < 3 ? 'llama32-1b'
        : hw.totalRamGb < 6 ? 'llama32-3b'
        : 'llama3-8b';

    res.status(200).json({
        status: 'OK',
        uptime: process.uptime(),
        activeModel,
        isBrainInstalled,
        totalRamGb: +(os.totalmem() / (1024 ** 3)).toFixed(1),
        freeRamGb: +(availableMemBytes() / (1024 ** 3)).toFixed(1),
        recommendedMaxParams: recommendation.maxParams,
        // Hardware profile for UI adaptation
        hardware: {
            tier: hw.tier,
            arch: hw.arch,
            isArm: hw.isArm,
            cpuCores: hw.cpuCores,
            tryGpuOffload: hw.tryGpuOffload,
        },
        contextOptions,
        recommendedModelId,
    });
});

export default router;
