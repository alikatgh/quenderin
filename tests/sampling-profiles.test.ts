import { readFileSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { describe, it, expect, afterEach } from 'vitest';
import {
    loadSamplingProfiles,
    loadSamplingProfilesDetailed,
    chatRepeatPenalty,
    agentDecisionTemperature,
    agentDecisionMaxTokens,
    agentDecisionMaxTokensCapped,
    EMBEDDED_SAMPLING_PROFILES,
    resetSamplingProfilesCache,
    candidatePaths,
} from '../src/services/samplingProfiles.js';

/**
 * Drives the canonical sampling profile file AND the shipped helper that LlmService uses.
 * Proves the JSON is well-formed, the helper reads the real file, embedded fallbacks match,
 * and a packaged (dist-only + shared) layout still loads without monorepo cwd.
 */
describe('shared/sampling-profiles.json', () => {
    const raw = readFileSync(join(process.cwd(), 'shared/sampling-profiles.json'), 'utf8');
    const profiles = JSON.parse(raw) as {
        chat: Record<string, number>;
        agent_decision: Record<string, number>;
        agent_deliberation: Record<string, number>;
    };

    it('defines chat, agent_decision, and agent_deliberation with required knobs', () => {
        for (const key of ['chat', 'agent_decision', 'agent_deliberation'] as const) {
            const p = profiles[key];
            expect(p).toBeDefined();
            for (const field of ['temperature', 'top_p', 'top_k', 'repeat_penalty', 'repeat_last_n', 'max_tokens']) {
                expect(typeof p[field]).toBe('number');
                expect(Number.isFinite(p[field])).toBe(true);
            }
        }
    });

    it('chat recipe matches the documented on-device defaults', () => {
        expect(profiles.chat).toMatchObject({
            temperature: 0.7,
            top_p: 0.95,
            top_k: 40,
            repeat_penalty: 1.1,
            repeat_last_n: 256,
            max_tokens: 512,
        });
    });

    it('agent_decision is the Qwen3 non-thinking grammar recipe', () => {
        expect(profiles.agent_decision).toMatchObject({
            temperature: 0.7,
            top_p: 0.8,
            top_k: 20,
            repeat_penalty: 1.1,
            max_tokens: 192,
        });
    });

    it('agent_deliberation is the hard-capped think-then-decide recipe', () => {
        expect(profiles.agent_deliberation).toMatchObject({
            temperature: 0.6,
            top_p: 0.95,
            top_k: 20,
            max_tokens: 256,
        });
    });
});

describe('samplingProfiles helper (shipped LlmService path)', () => {
    afterEach(() => {
        resetSamplingProfilesCache();
    });

    it('loadSamplingProfiles returns the same chat/agent numbers as the on-disk JSON', () => {
        const loaded = loadSamplingProfiles();
        const disk = JSON.parse(
            readFileSync(join(process.cwd(), 'shared/sampling-profiles.json'), 'utf8'),
        );
        expect(loaded.chat.repeat_penalty).toBe(disk.chat.repeat_penalty);
        expect(loaded.chat.repeat_last_n).toBe(disk.chat.repeat_last_n);
        expect(loaded.agent_decision.temperature).toBe(disk.agent_decision.temperature);
        expect(loaded.agent_decision.max_tokens).toBe(disk.agent_decision.max_tokens);
    });

    it('chatRepeatPenalty / agentDecision* helpers feed the real profile values', () => {
        const disk = JSON.parse(
            readFileSync(join(process.cwd(), 'shared/sampling-profiles.json'), 'utf8'),
        );
        expect(chatRepeatPenalty()).toEqual({
            penalty: disk.chat.repeat_penalty,
            lastTokens: disk.chat.repeat_last_n,
        });
        expect(agentDecisionTemperature()).toBe(disk.agent_decision.temperature);
        expect(agentDecisionMaxTokens()).toBe(disk.agent_decision.max_tokens);
    });

    it('agentDecisionMaxTokensCapped is the generateAction default (profile ∩ HW budget)', () => {
        const profile = agentDecisionMaxTokens();
        expect(profile).toBe(192);
        // Roomier HW: profile wins (not the old unbounded HW.actionMaxTokens alone).
        expect(agentDecisionMaxTokensCapped(256)).toBe(192);
        // Tight HW: never request more than the phone can afford.
        expect(agentDecisionMaxTokensCapped(64)).toBe(64);
        expect(agentDecisionMaxTokensCapped(100)).toBe(100);
    });

    it('EMBEDDED_SAMPLING_PROFILES stays lockstep with shared/sampling-profiles.json', () => {
        const disk = JSON.parse(
            readFileSync(join(process.cwd(), 'shared/sampling-profiles.json'), 'utf8'),
        );
        for (const key of ['chat', 'agent_decision', 'agent_deliberation'] as const) {
            for (const field of [
                'temperature',
                'top_p',
                'top_k',
                'repeat_penalty',
                'repeat_last_n',
                'max_tokens',
            ] as const) {
                expect(EMBEDDED_SAMPLING_PROFILES[key][field]).toBe(disk[key][field]);
            }
        }
    });

    it('loads via module-relative path when process.cwd has no shared/ (packaged cwd)', () => {
        const orig = process.cwd();
        const empty = join(tmpdir(), `q-sampling-cwd-${process.pid}`);
        mkdirSync(empty, { recursive: true });
        try {
            process.chdir(empty);
            resetSamplingProfilesCache();
            // cwd candidate fails; src/services → ../../shared still hits the monorepo file.
            const { profiles, source } = loadSamplingProfilesDetailed();
            expect(source).not.toBe('embedded');
            expect(source.includes('sampling-profiles.json')).toBe(true);
            expect(profiles.chat.repeat_penalty).toBe(1.1);
            expect(chatRepeatPenalty().penalty).toBe(1.1);
        } finally {
            process.chdir(orig);
            resetSamplingProfilesCache();
            rmSync(empty, { recursive: true, force: true });
        }
    });

    it('falls back to EMBEDDED when no candidate file exists (dist-only without shared/)', () => {
        // Point candidate search at a barren tree — no JSON anywhere.
        const barren = join(tmpdir(), `q-sampling-barren-${process.pid}`);
        mkdirSync(join(barren, 'dist', 'src', 'services'), { recursive: true });
        const origCwd = process.cwd();
        try {
            process.chdir(barren);
            // Use barren moduleDir so every relative path misses.
            const paths = candidatePaths(join(barren, 'dist', 'src', 'services'));
            expect(paths.every((p) => !existsSync(p))).toBe(true);

            // Direct unit: loadSamplingProfilesDetailed uses real moduleDir; instead assert
            // the embedded contract the pack-missing path uses.
            expect(EMBEDDED_SAMPLING_PROFILES.chat.repeat_penalty).toBe(1.1);
            expect(EMBEDDED_SAMPLING_PROFILES.agent_decision.temperature).toBe(0.7);

            // Simulate the exact load loop from a barren package root.
            let found: string | undefined;
            for (const p of paths) {
                try {
                    readFileSync(p, 'utf8');
                    found = p;
                    break;
                } catch {
                    /* miss */
                }
            }
            expect(found).toBeUndefined();
            // Shipped recovery: helpers still return embedded numbers via getSamplingProfiles
            // only if we can't find the real monorepo file — here we prove the barren path
            // set is empty so the real loader would take the embedded branch.
        } finally {
            process.chdir(origCwd);
            rmSync(barren, { recursive: true, force: true });
        }
    });
});

describe('packaged Electron layout (dist + shared, foreign cwd)', () => {
    const scratchRoot = join(
        process.env.SCRATCH || join(tmpdir(), 'q-sampling-pack'),
        `layout-${process.pid}`,
    );

    afterEach(() => {
        resetSamplingProfilesCache();
        rmSync(scratchRoot, { recursive: true, force: true });
    });

    it('resolves sampling-profiles from package-root shared/ next to dist/ (asar shape)', () => {
        // Mimic electron-builder files: packageRoot/{dist/src/services/*.js, shared/*.json}
        const pkg = scratchRoot;
        const svcDir = join(pkg, 'dist', 'src', 'services');
        const packagedJson = join(pkg, 'shared', 'sampling-profiles.json');
        mkdirSync(svcDir, { recursive: true });
        mkdirSync(join(pkg, 'shared'), { recursive: true });
        writeFileSync(
            packagedJson,
            readFileSync(join(process.cwd(), 'shared/sampling-profiles.json')),
        );

        // From dist/src/services, ../../../shared is the package-root shared/ (asar layout).
        const paths = candidatePaths(svcDir);
        expect(paths).toContain(packagedJson);
        expect(existsSync(packagedJson)).toBe(true);
        expect(JSON.parse(readFileSync(packagedJson, 'utf8')).chat.repeat_penalty).toBe(1.1);

        // Foreign cwd: monorepo cwd candidate misses; module-relative still hits packaged JSON.
        const orig = process.cwd();
        const empty = join(scratchRoot, 'empty-cwd');
        mkdirSync(empty, { recursive: true });
        try {
            process.chdir(empty);
            const still = candidatePaths(svcDir).filter((p) => existsSync(p));
            expect(still).toContain(packagedJson);
            // cwd/shared must NOT be the monorepo file anymore
            expect(existsSync(join(process.cwd(), 'shared', 'sampling-profiles.json'))).toBe(false);
        } finally {
            process.chdir(orig);
        }
    });

    it('electron-builder.yaml packs shared/**/* so asar layout includes the JSON', () => {
        const yaml = readFileSync(join(process.cwd(), 'electron-builder.yaml'), 'utf8');
        expect(yaml).toMatch(/shared\/\*\*\/\*/);
        // And still packs dist (where samplingProfiles.js lives).
        expect(yaml).toMatch(/dist\/\*\*\/\*/);
    });
});
