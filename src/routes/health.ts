import { Router } from 'express';
import fs from 'fs';
import os from 'os';
import { execSync } from 'child_process';
import { randomUUID } from 'crypto';
import { MODEL_CATALOG, modelPath, getHardwareRecommendation, getRecommendedModelIdForTotalRam } from '../constants.js';
import { availableMemBytes } from '../utils/memory.js';
import { getHardwareProfile } from '../utils/hardware.js';
import { getReadiness, getReadinessHistory } from '../services/readiness.service.js';

const router = Router();

const DIAGNOSTICS_SCHEMA_VERSION = '1.1.0';
const appVersion = process.env.npm_package_version ?? 'unknown';

const resolveCommitSha = (): string => {
    const fromEnv = process.env.QUENDERIN_GIT_SHA ?? process.env.GITHUB_SHA;
    if (fromEnv) return fromEnv.slice(0, 12);
    try {
        return execSync('git rev-parse --short=12 HEAD', { stdio: ['ignore', 'pipe', 'ignore'] })
            .toString()
            .trim();
    } catch {
        return 'unknown';
    }
};

const commitSha = resolveCommitSha();

/**
 * Shared LlmService reference — set via setLlmService() from server.ts.
 * This avoids circular imports while letting /health reflect the real loaded model.
 */
let llmServiceRef: {
    getActiveModelLabel: () => string;
    getModelLifecycleInfo?: () => { loadedModelId: string | null; loadedSinceMs: number; isGenerating: boolean };
} | null = null;

export function setHealthLlmService(service: {
    getActiveModelLabel: () => string;
    getModelLifecycleInfo?: () => { loadedModelId: string | null; loadedSinceMs: number; isGenerating: boolean };
}) {
    llmServiceRef = service;
}

router.get('/diagnostics', (req, res) => {
    const hw = getHardwareProfile();
    const readiness = getReadiness();
    const diagnosticsIdFromQuery = Array.isArray(req.query.diagnosticsId)
        ? req.query.diagnosticsId[0]
        : req.query.diagnosticsId;
    const diagnosticsIdFromHeader = req.header('x-diagnostics-id');
    const diagnosticsId = typeof diagnosticsIdFromQuery === 'string' && diagnosticsIdFromQuery.trim().length > 0
        ? diagnosticsIdFromQuery.trim()
        : typeof diagnosticsIdFromHeader === 'string' && diagnosticsIdFromHeader.trim().length > 0
            ? diagnosticsIdFromHeader.trim()
            : randomUUID();
    const historyLimitRaw = Array.isArray(req.query.historyLimit)
        ? req.query.historyLimit[0]
        : req.query.historyLimit;
    const parsedLimit = Number.parseInt(String(historyLimitRaw ?? ''), 10);
    const historyLimit = Number.isFinite(parsedLimit) ? parsedLimit : undefined;
    const readinessHistory = getReadinessHistory(historyLimit);
    const lifecycle = llmServiceRef?.getModelLifecycleInfo?.();
    const activeModel = llmServiceRef?.getActiveModelLabel() ?? 'not loaded';

    res.status(200).json({
        status: 'OK',
        diagnosticsId,
        diagnosticsSchemaVersion: DIAGNOSTICS_SCHEMA_VERSION,
        capturedAt: new Date().toISOString(),
        buildInfo: {
            appVersion,
            commitSha,
            nodeEnv: process.env.NODE_ENV ?? 'development',
            targetOs: process.env.TARGET_OS ?? 'android',
        },
        process: {
            pid: process.pid,
            nodeVersion: process.version,
            platform: process.platform,
            arch: process.arch,
            uptimeSec: Math.round(process.uptime()),
            rssMb: +((process.memoryUsage().rss || 0) / (1024 ** 2)).toFixed(1),
            heapUsedMb: +((process.memoryUsage().heapUsed || 0) / (1024 ** 2)).toFixed(1),
            heapTotalMb: +((process.memoryUsage().heapTotal || 0) / (1024 ** 2)).toFixed(1),
        },
        readiness,
        readinessHistory,
        llm: {
            activeModel,
            lifecycle: lifecycle ?? null,
        },
        hardware: {
            tier: hw.tier,
            arch: hw.arch,
            isArm: hw.isArm,
            cpuCores: hw.cpuCores,
            totalRamGb: +hw.totalRamGb.toFixed(1),
            tryGpuOffload: hw.tryGpuOffload,
        },
    });
});

router.get('/ready', (_req, res) => {
    const readiness = getReadiness();
    if (readiness.ready) {
        return res.status(200).json({ status: 'READY', ...readiness });
    }
    return res.status(503).json({ status: 'NOT_READY', ...readiness });
});

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
    const recommendedModelId = getRecommendedModelIdForTotalRam(hw.totalRamGb);

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
