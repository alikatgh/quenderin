/**
 * Load the canonical sampling recipes from shared/sampling-profiles.json.
 * Single source of truth for chat / agent_decision / agent_deliberation knobs
 * that are hand-ported into Swift/Kotlin/JNI (CI: check:sampling-parity).
 *
 * Resolution order (first hit wins):
 *   1. process.cwd()/shared/…          — monorepo / dev
 *   2. paths relative to this module   — src/ and dist/ layouts
 *   3. Electron resourcesPath / asar   — packaged desktop
 *   4. EMBEDDED fallback               — never throw on missing file so LlmService
 *                                        module-init cannot crash a packaged app
 *
 * electron-builder.yaml must list the shared/ tree so (3) succeeds in production;
 * (4) is the belt if a pack step regresses.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

export interface SamplingRecipe {
    temperature: number;
    top_p: number;
    top_k: number;
    repeat_penalty: number;
    repeat_last_n: number;
    max_tokens: number;
}

export interface SamplingProfiles {
    chat: SamplingRecipe;
    agent_decision: SamplingRecipe;
    agent_deliberation: SamplingRecipe;
}

/**
 * Byte-identical numeric recipes to shared/sampling-profiles.json.
 * Tests assert this stays in lockstep with the on-disk file. Used only when
 * every filesystem candidate misses (packaged app missing shared/, or tests
 * that simulate that layout).
 */
export const EMBEDDED_SAMPLING_PROFILES: SamplingProfiles = {
    chat: {
        temperature: 0.7,
        top_p: 0.95,
        top_k: 40,
        repeat_penalty: 1.1,
        repeat_last_n: 256,
        max_tokens: 512,
    },
    agent_decision: {
        temperature: 0.7,
        top_p: 0.8,
        top_k: 20,
        repeat_penalty: 1.1,
        repeat_last_n: 256,
        max_tokens: 192,
    },
    agent_deliberation: {
        temperature: 0.6,
        top_p: 0.95,
        top_k: 20,
        repeat_penalty: 1.1,
        repeat_last_n: 256,
        max_tokens: 256,
    },
};

const FILE_NAME = 'sampling-profiles.json';

/** Exported for tests that simulate a packaged layout. */
export function candidatePaths(moduleDir: string = path.dirname(fileURLToPath(import.meta.url))): string[] {
    const here = moduleDir;
    const paths: string[] = [
        path.join(process.cwd(), 'shared', FILE_NAME),
        // src/services → ../../shared
        path.join(here, '..', '..', 'shared', FILE_NAME),
        // dist/src/services → ../../../shared (package root when electron packs dist + shared)
        path.join(here, '..', '..', '..', 'shared', FILE_NAME),
        // dist/src/services → ../../../../shared (if outDir nests deeper)
        path.join(here, '..', '..', '..', '..', 'shared', FILE_NAME),
    ];
    // Electron packaged: resourcesPath is Contents/Resources (mac) or resources/ (win/linux).
    // With files: [shared/**/*], the JSON lands inside app.asar next to dist/.
    const resources = typeof process !== 'undefined' ? (process as NodeJS.Process & {
        resourcesPath?: string;
    }).resourcesPath : undefined;
    if (resources) {
        paths.push(path.join(resources, 'app.asar', 'shared', FILE_NAME));
        paths.push(path.join(resources, 'app', 'shared', FILE_NAME));
        paths.push(path.join(resources, 'shared', FILE_NAME));
    }
    return paths;
}

function parseProfiles(raw: string, used: string): SamplingProfiles {
    const parsed = JSON.parse(raw) as SamplingProfiles;
    for (const key of ['chat', 'agent_decision', 'agent_deliberation'] as const) {
        const r = parsed[key];
        if (!r || typeof r.temperature !== 'number' || typeof r.repeat_penalty !== 'number') {
            throw new Error(`sampling-profiles.json missing/invalid ${key} in ${used}`);
        }
    }
    return parsed;
}

export type LoadResult = { profiles: SamplingProfiles; source: string };

/**
 * Read profiles from disk or fall back to [EMBEDDED_SAMPLING_PROFILES].
 * Never throws solely because the file is absent — packaged Electron must boot.
 * Still throws if a found file is malformed (so pack/CI bugs surface).
 */
export function loadSamplingProfilesDetailed(): LoadResult {
    const tried = candidatePaths();
    for (const p of tried) {
        try {
            const raw = fs.readFileSync(p, 'utf8');
            return { profiles: parseProfiles(raw, p), source: p };
        } catch (e) {
            // ENOENT / not a file → try next. Malformed JSON from parseProfiles rethrows.
            if (e instanceof Error && e.message.includes('missing/invalid')) throw e;
            if (e instanceof SyntaxError) {
                throw new Error(`sampling-profiles.json is not valid JSON at ${p}: ${e.message}`);
            }
            /* try next path */
        }
    }
    console.warn(
        `[samplingProfiles] ${FILE_NAME} not found (tried: ${tried.join(', ')}); ` +
            'using EMBEDDED_SAMPLING_PROFILES. Pack the shared/ tree in electron-builder to load the file.',
    );
    return { profiles: EMBEDDED_SAMPLING_PROFILES, source: 'embedded' };
}

/** Read and validate (or embed). Prefer this over hard-coding knobs at call sites. */
export function loadSamplingProfiles(): SamplingProfiles {
    return loadSamplingProfilesDetailed().profiles;
}

/** Cached load for hot paths (llm.service). Tests can call resetSamplingProfilesCache(). */
let cached: SamplingProfiles | null = null;
export function getSamplingProfiles(): SamplingProfiles {
    if (!cached) cached = loadSamplingProfiles();
    return cached;
}

/** Test-only: drop the cache so the next load re-resolves paths. */
export function resetSamplingProfilesCache(): void {
    cached = null;
}

/** node-llama-cpp repeatPenalty shape from the chat recipe. */
export function chatRepeatPenalty(): { penalty: number; lastTokens: number } {
    const c = getSamplingProfiles().chat;
    return { penalty: c.repeat_penalty, lastTokens: c.repeat_last_n };
}

/**
 * Default temperature for grammar-constrained agent decisions when the caller
 * does not pass options.temperature. From agent_decision (not the old 0.1 default).
 * Explicit 0 (greedy) still wins via ?? at the call site.
 */
export function agentDecisionTemperature(): number {
    return getSamplingProfiles().agent_decision.temperature;
}

export function agentDecisionMaxTokens(): number {
    return getSamplingProfiles().agent_decision.max_tokens;
}
