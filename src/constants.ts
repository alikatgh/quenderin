import path from 'path';
import os from 'os';

const MODELS_DIR = path.join(os.homedir(), '.quenderin', 'models');

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
        url: 'https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true',
    },
    {
        id: 'llama32-3b',
        label: 'Llama 3.2 3B (Balanced)',
        filename: 'llama-3.2-3b-instruct.Q4_K_M.gguf',
        ramGb: 3.0,
        sizeLabel: '2.0 GB download',
        url: 'https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
    },
    {
        id: 'llama32-1b',
        label: 'Llama 3.2 1B (Light)',
        filename: 'llama-3.2-1b-instruct.Q4_K_M.gguf',
        ramGb: 1.5,
        sizeLabel: '0.8 GB download',
        url: 'https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
    },
] as const;

export type ModelEntry = typeof MODEL_CATALOG[number];

/** Resolves the full path for a model by its catalog id */
export function modelPath(id: string): string {
    const entry = MODEL_CATALOG.find(m => m.id === id);
    if (!entry) throw new Error(`Unknown model id: ${id}`);
    return path.join(MODELS_DIR, entry.filename);
}

/**
 * Legacy single-path export — points to whichever model the user last
 * selected (or default best). Can be overridden via LLM_MODEL_PATH env var.
 */
export const LLM_MODEL_PATH =
    process.env.LLM_MODEL_PATH ||
    path.join(MODELS_DIR, MODEL_CATALOG[0].filename);
