import path from 'path';
import os from 'os';
import { availableMemBytes } from './utils/memory.js';
import { getHardwareProfile } from './utils/hardware.js';

export const MODELS_DIR = path.join(os.homedir(), '.quenderin', 'models');

// ─── Memory Check Types (ported from off-grid-mobile) ───────────────────────

export type MemoryCheckSeverity = 'safe' | 'warning' | 'critical' | 'blocked';

export interface MemoryCheckResult {
    canLoad: boolean;
    severity: MemoryCheckSeverity;
    availableMemoryGB: number;
    requiredMemoryGB: number;
    remainingAfterLoadGB: number;
    message: string;
}

/** 85% of total = hard block, 65% = warning — more generous to actually let tiny models load */
export const MEMORY_BUDGET_HARD = 0.85;
export const MEMORY_BUDGET_WARNING = 0.65;
/** Overhead multiplier scales with model size — smaller models need less KV cache headroom */
export const MODEL_OVERHEAD_MULTIPLIER_BASE = 1.15;
export const MODEL_OVERHEAD_MULTIPLIER_LARGE = 1.3;

// ─── Quantization Reference (ported from off-grid-mobile) ───────────────────

export const QUANTIZATION_INFO: Record<string, {
    bitsPerWeight: number;
    quality: string;
    description: string;
    recommended: boolean;
}> = {
    'Q2_K':   { bitsPerWeight: 2.625, quality: 'Low',       description: 'Extreme compression, noticeable quality loss', recommended: false },
    'Q3_K_M': { bitsPerWeight: 3.5,   quality: 'Fair',      description: 'Moderate compression',                         recommended: false },
    'Q4_K_M': { bitsPerWeight: 4.5,   quality: 'Good',      description: 'Best balance of quality and size',             recommended: true },
    'Q5_K_M': { bitsPerWeight: 5.5,   quality: 'High',      description: 'Near original quality',                        recommended: false },
    'Q6_K':   { bitsPerWeight: 6.5,   quality: 'Very High', description: 'Minimal quality loss',                         recommended: false },
    'Q8_0':   { bitsPerWeight: 8,     quality: 'Excellent',  description: 'Best quantized quality',                       recommended: false },
};

// ─── RAM-Based Model Recommendations (ported from off-grid-mobile) ──────────
// Starts from 1GB for Raspberry Pi and other embedded devices.

export const MODEL_RECOMMENDATIONS = [
    { minRam: 1,  maxRam: 2,        maxParams: 1,    quantization: 'Q4_K_M' },
    { minRam: 2,  maxRam: 3,        maxParams: 1.5,  quantization: 'Q4_K_M' },
    { minRam: 3,  maxRam: 4,        maxParams: 1.5,  quantization: 'Q4_K_M' },
    { minRam: 4,  maxRam: 6,        maxParams: 3,    quantization: 'Q4_K_M' },
    { minRam: 6,  maxRam: 8,        maxParams: 4,    quantization: 'Q4_K_M' },
    { minRam: 8,  maxRam: 12,       maxParams: 8,    quantization: 'Q4_K_M' },
    { minRam: 12, maxRam: 16,       maxParams: 13,   quantization: 'Q4_K_M' },
    { minRam: 16, maxRam: 32,       maxParams: 30,   quantization: 'Q4_K_M' },
    { minRam: 32, maxRam: Infinity,  maxParams: 70,   quantization: 'Q4_K_M' },
];

// ─── Model Catalog ──────────────────────────────────────────────────────────

/**
 * Multi-model catalog sorted best → smallest.
 * ramGb = estimated peak RAM footprint including context overhead.
 */
export const MODEL_CATALOG = [
    {
        id: 'llama3-8b',
        label: 'Llama 3 8B (Best Quality)',
        filename: 'llama-3-instruct-8b.Q4_K_M.gguf',
        ramGb: 6.75,
        sizeLabel: '4.7 GB download',
        paramsBillions: 8,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true',
    },
    {
        id: 'llama32-3b',
        label: 'Llama 3.2 3B (Balanced)',
        filename: 'llama-3.2-3b-instruct.Q4_K_M.gguf',
        ramGb: 3.0,
        sizeLabel: '2.0 GB download',
        paramsBillions: 3,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
    },
    {
        id: 'llama32-1b',
        label: 'Llama 3.2 1B (Light)',
        filename: 'llama-3.2-1b-instruct.Q4_K_M.gguf',
        ramGb: 1.5,
        sizeLabel: '0.8 GB download',
        paramsBillions: 1,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
    },
    {
        id: 'llama32-1b-q2',
        label: 'Llama 3.2 1B Ultra-Light (Low RAM)',
        filename: 'llama-3.2-1b-instruct.Q2_K.gguf',
        ramGb: 0.7,
        sizeLabel: '0.4 GB download',
        paramsBillions: 1,
        quantization: 'Q2_K',
        url: 'https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true',
    },
] as const;

export type ModelEntry = typeof MODEL_CATALOG[number];

export function getRecommendedModelIdForTotalRam(totalRamGb: number): ModelEntry['id'] {
    if (totalRamGb < 1.5) return 'llama32-1b-q2';
    if (totalRamGb < 3) return 'llama32-1b';
    if (totalRamGb < 6) return 'llama32-3b';
    return 'llama3-8b';
}

/** Resolves the full path for a model by its catalog id */
export function modelPath(id: string): string {
    const entry = MODEL_CATALOG.find(m => m.id === id);
    if (!entry) throw new Error(`Unknown model id: ${id}`);
    return path.join(MODELS_DIR, entry.filename);
}

/** Check memory fitness for a specific model — uses hardware-adaptive budget */
export function checkMemoryForModel(entry: ModelEntry): MemoryCheckResult {
    const hw = getHardwareProfile();
    const freeGb = availableMemBytes() / (1024 ** 3);
    const totalGb = os.totalmem() / (1024 ** 3);
    // Smaller models need proportionally less overhead (KV cache is smaller)
    const overhead = entry.paramsBillions <= 3 ? MODEL_OVERHEAD_MULTIPLIER_BASE : MODEL_OVERHEAD_MULTIPLIER_LARGE;
    const required = entry.ramGb * overhead;
    const remaining = freeGb - required;
    const usageAfterLoad = (totalGb - freeGb + required) / totalGb;

    // Use hardware-specific budget — Pi gets 92% (let it swap) vs desktop 85%
    if (usageAfterLoad > hw.memoryBudgetHard) {
        return {
            canLoad: false,
            severity: 'blocked',
            availableMemoryGB: freeGb,
            requiredMemoryGB: required,
            remainingAfterLoadGB: remaining,
            message: `Loading ${entry.label} needs ~${required.toFixed(1)}GB but only ${freeGb.toFixed(1)}GB is free. Close some apps or choose a smaller model.`,
        };
    }
    if (usageAfterLoad > MEMORY_BUDGET_WARNING) {
        return {
            canLoad: true,
            severity: 'warning',
            availableMemoryGB: freeGb,
            requiredMemoryGB: required,
            remainingAfterLoadGB: remaining,
            message: `${entry.label} will leave only ${remaining.toFixed(1)}GB free. System may be slow.`,
        };
    }
    return {
        canLoad: true,
        severity: 'safe',
        availableMemoryGB: freeGb,
        requiredMemoryGB: required,
        remainingAfterLoadGB: remaining,
        message: `${entry.label} fits comfortably.`,
    };
}

/** Get the recommended max model params for current hardware */
export function getHardwareRecommendation(): { maxParams: number; quantization: string; totalRamGb: number } {
    const totalRamGb = os.totalmem() / (1024 ** 3);
    const tier = MODEL_RECOMMENDATIONS.find(t => totalRamGb >= t.minRam && totalRamGb < t.maxRam);
    return {
        maxParams: tier?.maxParams ?? 1,   // default to 1B for unknown/tiny hardware
        quantization: tier?.quantization ?? 'Q4_K_M',
        totalRamGb,
    };
}

// ─── Allowed settings values (for WS input validation) ─────────────────────

export const ALLOWED_CONTEXT_SIZES = [256, 512, 1024, 2048, 4096, 8192] as const;

/**
 * Legacy single-path export — points to whichever model the user last
 * selected (or default best). Can be overridden via LLM_MODEL_PATH env var.
 */
export const LLM_MODEL_PATH =
    process.env.LLM_MODEL_PATH ||
    path.join(MODELS_DIR, MODEL_CATALOG[0].filename);
