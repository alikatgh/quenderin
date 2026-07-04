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
        id: 'qwen3-14b',
        label: 'Qwen3 14B (Best Quality)',
        filename: 'qwen3-14b.Q4_K_M.gguf',
        ramGb: 11.0,
        sizeLabel: '9.0 GB download',
        paramsBillions: 14,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf?download=true',
        sha256: '500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0',
    },
    {
        id: 'gemma4-12b',
        label: 'Gemma 4 12B (Multilingual)',
        filename: 'gemma-4-12b-it.Q4_K_M.gguf',
        ramGb: 9.0,
        sizeLabel: '7.4 GB download',
        paramsBillions: 12,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/ggml-org/gemma-4-12B-it-GGUF/resolve/main/gemma-4-12B-it-Q4_K_M.gguf?download=true',
        sha256: '1278394b693672ac2799eadc9a83fd98259a6a88a40acfb1dcaa6c6fc895a606',
    },
    {
        id: 'qwen25-coder-7b',
        label: 'Qwen2.5 Coder 7B (Coding)',
        filename: 'qwen2.5-coder-7b-instruct.Q4_K_M.gguf',
        ramGb: 6.5,
        sizeLabel: '4.7 GB download',
        paramsBillions: 7,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf?download=true',
        sha256: '509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c',
    },
    {
        id: 'deepseek-r1-7b',
        label: 'DeepSeek-R1 7B (Reasoning)',
        filename: 'deepseek-r1-distill-qwen-7b.Q4_K_M.gguf',
        ramGb: 6.5,
        sizeLabel: '4.7 GB download',
        paramsBillions: 7,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf?download=true',
        sha256: '731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b',
    },
    {
        id: 'llama3-8b',
        label: 'Llama 3 8B (Best Quality)',
        filename: 'llama-3-instruct-8b.Q4_K_M.gguf',
        ramGb: 6.75,
        sizeLabel: '4.7 GB download',
        paramsBillions: 8,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true',
        sha256: 'ab9e4eec7e80892fd78f74d9a15d0299f1e22121cea44efd68a7a02a3fe9a1da',
    },
    {
        id: 'mistral-7b',
        label: 'Mistral 7B (All-Rounder)',
        filename: 'mistral-7b-instruct-v0.3.Q4_K_M.gguf',
        ramGb: 6.0,
        sizeLabel: '4.1 GB download',
        paramsBillions: 7,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf?download=true',
        sha256: '1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6',
    },
    {
        id: 'gemma3-4b',
        label: 'Gemma 3 4B (Multilingual)',
        filename: 'gemma-3-4b-it.Q4_K_M.gguf',
        ramGb: 3.8,
        sizeLabel: '2.5 GB download',
        paramsBillions: 4,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf?download=true',
        sha256: '04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19',
    },
    {
        id: 'qwen3-4b',
        label: 'Qwen3 4B (Everyday)',
        filename: 'qwen3-4b.Q4_K_M.gguf',
        ramGb: 3.6,
        sizeLabel: '2.4 GB download',
        paramsBillions: 4,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true',
        sha256: '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
    },
    {
        id: 'phi4-mini',
        label: 'Phi-4 Mini 3.8B (Efficient)',
        filename: 'phi-4-mini-instruct.Q4_K_M.gguf',
        ramGb: 3.4,
        sizeLabel: '2.3 GB download',
        paramsBillions: 3.8,
        quantization: 'Q4_K_M',
        url: 'https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf?download=true',
        sha256: '88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a',
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
        sha256: 'e4f1a04d927b09ec18eb2f233d85ecd760fc2d35cec97e37f8604d3632210d9a',
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
        sha256: 'f7ede42862ceca07ad1c88a97b67520019c4ac7e5ced250d2e696fa62ab189af',
    },
    {
        id: 'llama32-1b-q2',
        label: 'Llama 3.2 1B Ultra-Light (Low RAM)',
        filename: 'llama-3.2-1b-instruct.Q2_K.gguf',
        ramGb: 0.7,
        sizeLabel: '0.4 GB download',
        paramsBillions: 1,
        quantization: 'Q2_K',
        url: 'https://huggingface.co/unsloth/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true',
        sha256: '8b7091a92bc10d70392a91ebe06cd43e1f5048ae0162e88f8fbe8445447ceae8',
    },
] as const;

export type ModelEntry = typeof MODEL_CATALOG[number];

export function getRecommendedModelIdForTotalRam(totalRamGb: number): ModelEntry['id'] {
    if (totalRamGb < 1.5) return 'llama32-1b-q2';
    if (totalRamGb < 3) return 'llama32-1b';
    if (totalRamGb < 4) return 'llama32-3b';
    if (totalRamGb < 10) return 'qwen3-4b';   // the current go-to for mainstream devices
    return 'qwen3-14b';
}

/**
 * The recommendation callers can actually OFFER: the RAM-band pick when it passes the
 * memory gate, else the largest catalog model that does (falling back to the smallest).
 * Mirrors ModelRecommender.bestInstallableModel in the Swift/Kotlin ports — the band
 * and checkMemoryForModel can disagree (a 16 GB machine band-picks the 14B, which the
 * 85% budget then blocks), and a recommendation must never sit on a model the same
 * surface refuses to install. The band function above stays 1:1 with the ports and
 * its boundary tests — don't fold this logic into it.
 */
export function getBestInstallableModel(totalRamGb: number): ModelEntry['id'] {
    const bandedId = getRecommendedModelIdForTotalRam(totalRamGb);
    const banded = MODEL_CATALOG.find(m => m.id === bandedId);
    if (banded && checkMemoryForModel(banded).canLoad) return bandedId;
    let fitting: ModelEntry | undefined;
    for (const m of MODEL_CATALOG) {
        if ((!fitting || m.ramGb > fitting.ramGb) && checkMemoryForModel(m).canLoad) fitting = m;
    }
    return (fitting ?? MODEL_CATALOG[MODEL_CATALOG.length - 1]).id;
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
            message: `Loading ${entry.label} needs ~${required.toFixed(1)}GB of memory — more than this device can safely spare (${freeGb.toFixed(1)}GB free of ${totalGb.toFixed(1)}GB). Close other apps or choose a smaller model.`,
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

// ─── Limits & Thresholds ─────────────────────────────────────────────────────
// Centralized to avoid scattering magic numbers across services.

/** Max sessions before oldest are pruned */
export const MAX_SESSIONS = 100;
/** Max messages retained per session */
export const MAX_MESSAGES_PER_SESSION = 500;
/** Max length for user-supplied goal text (prevents DoS via mega-strings) */
export const MAX_GOAL_LENGTH = 4000;
/** Max length for a single chat message */
export const MAX_CHAT_LENGTH = 8000;
/** Max buffered bytes on a WebSocket before dropping messages */
export const MAX_SEND_BUFFER_BYTES = 1024 * 1024; // 1 MB
/** Max attachments per WebSocket message */
export const MAX_ATTACHMENTS = 10;
/** Max size of a single attachment in bytes */
export const MAX_ATTACHMENT_SIZE = 1024 * 1024; // 1 MB
/** Background daemon visual diff threshold to trigger LLM */
export const VISUAL_DIFF_THRESHOLD = 0.05;
/** Temp file max age before cleanup (1 hour) */
export const TEMP_FILE_MAX_AGE_MS = 60 * 60 * 1000;
/** Temp file cleanup interval (30 min) */
export const TEMP_CLEANUP_INTERVAL_MS = 30 * 60 * 1000;
/** Session flush debounce interval */
export const SESSION_FLUSH_INTERVAL_MS = 2000;
/** WebSocket heartbeat interval */
export const WS_HEARTBEAT_INTERVAL_MS = 30_000;

// ─── Allowed settings values (for WS input validation) ─────────────────────

export const ALLOWED_CONTEXT_SIZES = [256, 512, 1024, 2048, 4096, 8192] as const;
