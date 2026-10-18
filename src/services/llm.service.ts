import {
    agentDecisionMaxTokensCapped,
    agentDecisionTemperature,
    chatRepeatPenalty,
} from './samplingProfiles.js';

// node-llama-cpp is a native module that may not compile on exotic architectures.
// We import it dynamically and provide a clear error if unavailable.
type LlamaModel = any;
type LlamaContext = any;
type LlamaChatSession = any;

let _llamaBindings: {
    getLlama: any;
    LlamaModel: any;
    LlamaContext: any;
    LlamaChatSession: any;
    LlamaLogLevel: any;
    defineChatSessionFunction: any;
    InputLookupTokenPredictor: any;
    weeklyWrappers: any;
} | null = null;
let _llamaImportError: Error | null = null;

try {
    const mod = await import("node-llama-cpp");
    _llamaBindings = {
        getLlama: mod.getLlama,
        LlamaModel: mod.LlamaModel,
        LlamaContext: mod.LlamaContext,
        LlamaChatSession: mod.LlamaChatSession,
        LlamaLogLevel: mod.LlamaLogLevel,
        defineChatSessionFunction: mod.defineChatSessionFunction,
        InputLookupTokenPredictor: mod.InputLookupTokenPredictor,
        weeklyWrappers: mod,
    };
} catch (err) {
    _llamaImportError = err instanceof Error ? err : new Error(String(err));
    // Logger isn't imported yet at this point (top-level await), so we use console.error here.
    // This is acceptable because it only fires once at startup when the native module is missing.
    console.error(
        `[LLM] node-llama-cpp is not available on this platform (${process.arch}/${process.platform}). ` +
        `Local LLM inference is disabled. The dashboard UI and API will still work, but ` +
        `chat/agent features require a supported architecture (x86_64 or arm64).`
    );
}

import path from "path";
import os from "os";
import fs from "fs";
import { availableMemBytes } from "../utils/memory.js";
import { EventEmitter } from "events";
import { ILlmProvider, GenerationMeta, GenerationOptions } from "../types/index.js";
import { MODEL_CATALOG, modelPath, checkMemoryForModel, gpuOffloadFits, type ModelEntry, type MemoryCheckResult } from "../constants.js";
import { stripControlTokens, stripControlTokensWithOptions } from "../utils/stripControlTokens.js";
import { getPresetById, type Preset } from "./presets.js";
import { buildToolPrompt, maxToolCallsPerResponse } from "./tools/registry.js";
import { hasToolCalls, parseToolCalls, stripToolCalls, formatToolResults } from "./tools/toolLoop.js";
import { executeToolCalls } from "./tools/handlers.js";
import { buildNativeChatFunctions } from "./tools/nativeFunctions.js";
import { getHardwareProfile } from "../utils/hardware.js";
import { verifyModelIntegrity } from "./modelIntegrity.js";
import { planDownloadWrite, planDownloadSegments, downloadConnectionCount, parseContentRangeTotal } from "./modelDownloadPlan.js";
import type { DownloadSegment } from "./modelDownloadPlan.js";
import type { FileHandle } from "fs/promises";
import logger from "../utils/logger.js";
import { jaisChatWrapper } from './weeklyChatWrappers.js';
import { PublisherChatSession } from './publisherChat.js';
import { isBeamIdentity, isMuseIdentity } from './multipartModels.js';
import { installMultipartModel, verifyMultipartModel } from './multipartInstaller.js';
import { readGgufModelIdentity } from './ggufModelIdentity.js';
import { nativeWorkloads } from './nativeWorkloads.js';
import {
    getModelRuntimeCompatibility, isPrismRuntime, modelRuntimeError, requiresPrismRuntime,
    type ModelRuntimeCompatibility, type NodeLlamaRuntime, type RuntimeModelDescriptor,
} from './modelRuntime.js';

/** Narrow unknown catch to an Error-like shape with optional `code` */
function errCode(e: unknown): string | undefined {
    return e instanceof Error ? (e as NodeJS.ErrnoException).code : undefined;
}

/** Check the compiled type table as well as the addon's source metadata. The pinned
 * node-llama-cpp wrappers return undefined for IDs beyond the stock type table. */
function hasPrismTensorTypes(runtime: NodeLlamaRuntime & {
    _bindings?: {
        getBlockSizeForGgmlType?: (type: number) => unknown;
        getTypeSizeForGgmlType?: (type: number) => unknown;
    };
}): boolean {
    try {
        const bindings = runtime._bindings;
        if (typeof bindings?.getBlockSizeForGgmlType !== 'function'
            || typeof bindings.getTypeSizeForGgmlType !== 'function') return false;
        return bindings.getBlockSizeForGgmlType(142) === 128
            && bindings.getTypeSizeForGgmlType(142) === 34
            && bindings.getBlockSizeForGgmlType(143) === 128
            && bindings.getTypeSizeForGgmlType(143) === 28;
    } catch {
        return false;
    }
}

function runtimeCapabilities(runtime: any): NodeLlamaRuntime {
    let weeklyTextABI = 0;
    let beamABI = 0, museSparkABI = 0, contextAbortABI = 0;
    try { contextAbortABI = runtime?._bindings?.getQuenderinContextAbortABI?.() === 1 ? 1 : 0; } catch { /* Missing or stale native capabilities remain unavailable. */ }
    try { beamABI = contextAbortABI === 1 && runtime?._bindings?.getQuenderinBeamRuntimeABI?.() === 1 ? 1 : 0; } catch { /* Missing or stale native capabilities remain unavailable. */ }
    try { museSparkABI = contextAbortABI === 1 && runtime?._bindings?.getQuenderinMuseSparkRuntimeABI?.() === 1 ? 1 : 0; } catch { /* Missing or stale native capabilities remain unavailable. */ }
    try { weeklyTextABI = runtime?._bindings?.getQuenderinWeeklyTextRuntimeABI?.() === 1 ? 1 : 0; }
    catch { /* Old or replaced addons cannot enable new architectures. */ }
    return { buildType: runtime?.buildType, llamaCppRelease: runtime?.llamaCppRelease, weeklyTextABI, beamABI, museSparkABI };
}

/** Error carrying a structured `code` plus optional model hints for action_required events. */
interface TaggedError extends NodeJS.ErrnoException {
    fittingModels?: unknown;
}

// ─── Hardware-adaptive profile (detected once at startup) ───────────────────
const HW = getHardwareProfile();

// ─── Decode guards (mirror the Swift twin; node-llama-cpp ships these OFF) ───
/** Repetition penalty from shared/sampling-profiles.json → chat (CI: check:sampling-parity).
 *  Without it, heavily-quantized small models loop the same paragraph verbatim. */
const _chatRepeat = chatRepeatPenalty();
const REPEAT_PENALTY = _chatRepeat.penalty;
const REPEAT_LAST_N = _chatRepeat.lastTokens;
/** No-think CHAT: node-llama-cpp counts hidden <think> tokens against the maxTokens cap, so on tight
 *  hardware (chatMaxTokens 128-384) a reasoning-heavy Qwen3 turn can spend its whole budget thinking
 *  and return an empty/truncated answer. Setting the reasoning budget to 0 disables thinking on the
 *  chat path — matching the Swift app's deliberate no-think chat close — so the visible answer always
 *  gets the full budget. The grammar-forced JSON agent path never thinks and is untouched. */
const CHAT_THOUGHT_TOKEN_BUDGET = 0;

// ─── Performance: Model-aware context caps ──────────────────────────────────
// Larger context = more KV cache memory = slower inference.
// Small models (1B) can't effectively use huge contexts anyway.
const MODEL_MAX_CONTEXT: Record<number, number> = {
    1:  2048,   // 1B model: 2048 is the sweet spot
    3:  4096,   // 3B model: can handle more but diminishing returns
    8:  8192,   // 8B model: full context only on large-RAM systems
};

/** Determine the best context size given model, RAM, user preference, and hardware tier. */
function resolveContextForSituation(
    entry: ModelEntry,
    freeRamGb: number,
    userSetting: number,
    degraded: boolean
): number {
    // Hard degraded mode — absolute minimum for the hardware
    if (degraded) return HW.contextFloor;

    // 1) Model-aware cap: don't waste KV cache on models that can't use it
    const modelCap = MODEL_MAX_CONTEXT[entry.paramsBillions] ?? 4096;

    // 2) RAM-aware cap: scale down if free memory is tight
    let ramCap: number;
    if (freeRamGb < 1.0)       ramCap = 256;
    else if (freeRamGb < 1.5)  ramCap = 512;
    else if (freeRamGb < 2.5)  ramCap = 1024;
    else if (freeRamGb < 4)    ramCap = 2048;
    else if (freeRamGb < 6)    ramCap = 4096;
    else                       ramCap = 8192;

    // 3) Pick the minimum of user preference, model cap, and RAM cap
    const effective = Math.min(userSetting, modelCap, ramCap);
    return Math.max(effective, HW.contextFloor);
}

/**
 * Pick the best catalog model that fits available RAM.
 *
 * Graceful degradation strategy:
 * 1. Try each downloaded model smallest-first against the RAM budget.
 * 2. If memory safety is on but nothing passes the budget, STILL return the
 *    smallest downloaded standard model with `degraded: true` so the caller can load it
 *    with a minimal context instead of blocking the entire app.
 * 3. Prism models must always pass the RAM gate; return null if no eligible file exists.
 */
function selectBestModel(memorySafetyEnabled: boolean, runtime?: NodeLlamaRuntime): { entry: ModelEntry; path: string; degraded: boolean } | null {
    // Prefer responsiveness first (smallest -> largest) to avoid long blocking TTFT on CPU-only hosts.
    const prioritized = [...MODEL_CATALOG].sort((a, b) => a.paramsBillions - b.paramsBillions);
    let smallestDownloaded: { entry: ModelEntry; path: string } | null = null;

    for (const entry of prioritized) {
        // Experimental models are explicit choices. A missing selection must not
        // silently switch a conversation to a newly downloaded model family.
        if (requiresPrismRuntime(entry)) continue;
        // An unsupported model must never enter the low-memory fallback either.
        if (!getModelRuntimeCompatibility(entry, runtime).canLoad) continue;
        const filePath = modelPath(entry.id);
        // Must exist on disk
        if (!fs.existsSync(filePath)) continue;
        const prismRequired = requiresPrismRuntime(entry);
        if (prismRequired && !checkMemoryForModel(entry, runtime).canLoad) continue;
        // Track the smallest downloaded model as a last-resort fallback
        if (!prismRequired && !smallestDownloaded) smallestDownloaded = { entry, path: filePath };
        // If safety is on, check it fits
        if (memorySafetyEnabled && !prismRequired) {
            const memCheck = checkMemoryForModel(entry, runtime);
            if (!memCheck.canLoad) continue;
        }
        return { entry, path: filePath, degraded: false };
    }

    // Nothing passed the budget but we have at least one model on disk —
    // return it in degraded mode so the app still works (slowly) instead of blocking.
    if (smallestDownloaded) {
        return { ...smallestDownloaded, degraded: true };
    }
    return null;
}

/**
 * Honor a pinned activeModelId when its file exists; otherwise fall back to auto-selection.
 */
function selectPinnedOrBestModel(
    activeModelId: string,
    memorySafetyEnabled: boolean,
    runtime?: NodeLlamaRuntime,
): { entry: ModelEntry; path: string; degraded: boolean } | null {
    const pinned = MODEL_CATALOG.find((m) => m.id === activeModelId);
    if (pinned && getModelRuntimeCompatibility(pinned, runtime).canLoad) {
        const filePath = modelPath(pinned.id);
        if (fs.existsSync(filePath)) {
            const prismRequired = requiresPrismRuntime(pinned);
            if (!memorySafetyEnabled && !prismRequired) {
                return { entry: pinned, path: filePath, degraded: false };
            }
            const memCheck = checkMemoryForModel(pinned, runtime);
            if (memCheck.canLoad) {
                return { entry: pinned, path: filePath, degraded: false };
            }
            if (!prismRequired) return { entry: pinned, path: filePath, degraded: true };
        }
    }
    return selectBestModel(memorySafetyEnabled, runtime);
}

export class LlmService extends EventEmitter implements ILlmProvider {
    private unregisterWorkload: () => void;
    private disposal: Promise<void> = Promise.resolve();
    private parkedChatHistory: { modelId: string; presetId: string; history: any } | null = null;
    private modelInstance: LlamaModel | null = null;
    private contextInstance: LlamaContext | null = null;
    private initPromise: Promise<{ model: LlamaModel, context: LlamaContext }> | null = null;
    private nativeLoadPending = false;
    private shuttingDown = false;
    private shutdownTask: Promise<void> | undefined;
    private nativeAborts = new Set<AbortController>();
    private nativeInitializations = new Set<Promise<unknown>>();
    private isDownloading: boolean = false;
    private generalChatSession: LlamaChatSession | null = null;
    /** The engine handle from getLlama() — retained ONLY so shutdown() can dispose the
     *  Metal/GPU device before exit (see shutdown's doc comment). */
    private llamaEngine: { dispose(): Promise<void> } | null = null;
    /** Probe only an existing addon; never download/build native code from a model request. */
    private prismRuntimeProbe: Promise<NodeLlamaRuntime | undefined> | null = null;
    private isGeneratingChat: boolean = false;
    /** Q-292: cancel handle for the CURRENT chat generation. Non-null only while `generalChat`
     *  is streaming; `requestChatCancel()` aborts it so a user "stop" ends the native decode within
     *  a token instead of waiting out the 30s prompt timeout. Chat-only — the agent has pause/stop. */
    private chatAbort: AbortController | null = null;
    /** Agent/daemon generateAction calls share the same model but do not use the chat session. */
    private isGeneratingAction: boolean = false;
    private tokenBuffer: string = "";
    private activeModelId: string = MODEL_CATALOG[0].id;
    private activePreset: Preset = getPresetById('general');
    private currentSettings = {
        contextSize: 2048,  // user-facing setting; actual context is resolved per-situation
        memorySafetyEnabled: true
    };
    /** Cached reference to the loaded model entry for per-request decisions */
    private activeModelEntry: ModelEntry | null = null;

    // ─── Structured decoding + KV prefix reuse (the agent-reliability core) ──
    /** Compiled grammars keyed by schema JSON. Grammars belong to the llama ENGINE, so the cache
     *  is cleared whenever the engine handle is replaced or the model is unloaded. */
    private grammarCache = new Map<string, any>();
    /** Long-lived context sequences keyed by GenerationOptions.cacheKey. A reused sequence keeps
     *  its KV state, so node-llama-cpp only prefills the part of the next prompt that diverges
     *  from the previous one — the agent's per-step cost drops from "entire prompt" to "what
     *  actually changed on screen". Sequences belong to the CONTEXT: cleared on unload. */
    private actionSequences = new Map<string, any>();

    /** Compile (once) a grammar that forces output to conform to `schema`. Returns null when the
     *  engine can't build one (old bindings, unsupported schema feature) — callers then decode
     *  unconstrained, which is exactly the pre-grammar behavior. */
    private async grammarForSchema(schema: Record<string, unknown>): Promise<any | null> {
        const engine = this.llamaEngine as any;
        if (!engine || typeof engine.createGrammarForJsonSchema !== 'function') return null;
        const key = JSON.stringify(schema);
        const cached = this.grammarCache.get(key);
        if (cached) return cached;
        try {
            const grammar = await engine.createGrammarForJsonSchema(schema);
            this.grammarCache.set(key, grammar);
            return grammar;
        } catch (err) {
            logger.warn('[LLM] Grammar compilation failed — decoding unconstrained:', err instanceof Error ? err.message : err);
            return null;
        }
    }

    /** Drop (and dispose) the persistent sequence for one cacheKey. Public via ILlmProvider so the
     *  agent can free the mission's KV memory the moment the mission ends. */
    public releaseActionCache(cacheKey: string): void {
        const seq = this.actionSequences.get(cacheKey);
        if (!seq) return;
        this.actionSequences.delete(cacheKey);
        try { seq.dispose(); } catch { /* already disposed */ }
    }

    private releaseAllActionCaches(): void {
        for (const key of [...this.actionSequences.keys()]) this.releaseActionCache(key);
    }

    // ─── Active Model Lifecycle (ported from off-grid-mobile) ───────────────
    private loadedModelId: string | null = null;
    private modelLoadTimestamp: number = 0;
    /** Tracks actual GPU backend used after init (for diagnostics) */
    private gpuBackendUsed: string = 'unknown';
    /** The context size the fallback chain ACTUALLY created — can be half (or the floor) of what was
     *  requested. Session policy must budget against this, not the user setting (Q-415's sibling:
     *  the log told the truth but the TURN BUDGET still believed the setting). 0 = no context yet. */
    private actualContextSize: number = 0;
    private flashAttentionActive: boolean = false;
    /** Init timeout scaled by hardware: 45s × HW.timeoutMultiplier (e.g. 225s on Pi) */
    private readonly modelInitTimeoutMs: number = Math.round(45_000 * HW.timeoutMultiplier);
    /** Prompt timeout scaled by hardware: 30s × HW.timeoutMultiplier */
    private readonly promptTimeoutMs: number = Math.round(30_000 * HW.timeoutMultiplier);
    /** Idle timeout — unload model after N minutes of inactivity to free RAM */
    private idleTimeoutMs: number;
    private idleTimer: NodeJS.Timeout | null = null;
    private lastActivityTimestamp: number = 0;
    /** Memory pressure monitor — checks heap usage periodically while model is loaded */
    private memoryPressureTimer: NodeJS.Timeout | null = null;

    public getActiveModelLabel(): string {
        return MODEL_CATALOG.find(m => m.id === this.activeModelId)?.label ?? this.activeModelId;
    }

    /** The pinned/auto-selected model id — lets the catalog endpoint mark the active row (r9 H1). */
    public getActiveModelId(): string {
        return this.activeModelId;
    }

    /** Create a LlamaChatSession using the dynamically imported class */
    private createChatSession(opts: { contextSequence: any; systemPrompt?: string; autoDisposeSequence?: boolean }): any {
        if (!_llamaBindings) throw new Error('LLM bindings not available');
        // autoDisposeSequence (default true): disposing the session frees its KV-cache sequence slot.
        // Without it, each session rotation leaks a slot and context.getSequence() eventually throws
        // "No sequences left" — chat then fails permanently until a full model reload.
        // generateAction's cacheKey path passes false: it OWNS its sequence across calls (KV prefix
        // reuse) and frees it via releaseActionCache/unloadModel instead.
        if (this.isPublisherSelected()) return new PublisherChatSession(isBeamIdentity(this.activeModelEntry ?? {}) ? 'beam' : 'muse',
            opts.contextSequence, opts.systemPrompt ?? '', _llamaBindings.weeklyWrappers);
        return new _llamaBindings.LlamaChatSession({ autoDisposeSequence: true, ...opts,
            ...(this.isJaisSelected() ? { chatWrapper: jaisChatWrapper(_llamaBindings.weeklyWrappers) } : {}) });
    }

    private isPublisherSelected(): boolean { return !!this.activeModelEntry && (isBeamIdentity(this.activeModelEntry) || isMuseIdentity(this.activeModelEntry)); }

    private isJaisSelected(): boolean { return /^jais3-/i.test(this.loadedModelId ?? this.activeModelId); }

    /** Dispose the general chat session (freeing its KV-cache sequence slot) and clear it. */
    private disposeChatSession(): void {
        try { this.generalChatSession?.dispose(); } catch { /* already disposed */ }
        this.generalChatSession = null;
    }

    /** Start the conversation over without unloading the model (CLI `/clear`, UI "new chat"). */
    public resetChat(): void {
        this.parkedChatHistory = null;
        this.disposeChatSession();
    }

    constructor() {
        super();
        this.unregisterWorkload = nativeWorkloads.register(this);
        this.idleTimeoutMs = this.resolveIdleTimeoutMs();
        logger.log(`[Hardware] ${HW.tier} tier detected: ${HW.platform}/${HW.arch}, ${HW.cpuCores} cores, ${HW.totalRamGb.toFixed(1)}GB RAM, GPU=${HW.tryGpuOffload}, nativeAddons=${HW.nativeAddonsLikely}, timeoutX=${HW.timeoutMultiplier}`);
    }

    /** Q-543: how long after the last inference the model is protected from a pressure-unload. Agent
     *  steps are seconds apart and `isInferenceBusy()` is false BETWEEN them, so without this grace the
     *  pressure monitor unloads mid-run and the very next step reloads (churn/latency). A live session
     *  keeps the model; a genuinely-idle one under pressure still unloads once the grace lapses. */
    private static readonly PRESSURE_ACTIVE_GRACE_MS = 30_000;

    /** True when critical memory pressure warrants unloading: over the hard budget, not mid-inference,
     *  and not within the recent-activity grace (Q-543). Pure over instance state so it's unit-tested. */
    private shouldUnloadUnderPressure(usageRatio: number, nowMs: number): boolean {
        if (usageRatio <= HW.memoryBudgetHard) return false;
        if (this.isInferenceBusy()) return false;
        return (nowMs - this.lastActivityTimestamp) > LlmService.PRESSURE_ACTIVE_GRACE_MS;
    }

    /** Start periodic memory pressure checks while model is loaded */
    private startMemoryPressureMonitor(): void {
        if (this.memoryPressureTimer) return;
        this.memoryPressureTimer = setInterval(() => {
            if (!this.modelInstance) {
                this.stopMemoryPressureMonitor();
                return;
            }
            const freeGb = availableMemBytes() / (1024 ** 3);
            const totalGb = os.totalmem() / (1024 ** 3);
            const usageRatio = 1 - (freeGb / totalGb);

            if (this.shouldUnloadUnderPressure(usageRatio, Date.now())) {
                logger.warn(`[Memory] Pressure critical (${(usageRatio * 100).toFixed(0)}% used, ${freeGb.toFixed(1)}GB free). Unloading model to prevent OOM.`);
                this.unloadModel();
            } else if (usageRatio > HW.memoryBudgetHard * 0.95) {
                logger.warn(`[Memory] Pressure high (${(usageRatio * 100).toFixed(0)}% used, ${freeGb.toFixed(1)}GB free). Model may be unloaded soon.`);
            }
        }, 15_000); // Check every 15 seconds
        this.memoryPressureTimer.unref();
    }

    private stopMemoryPressureMonitor(): void {
        if (this.memoryPressureTimer) {
            clearInterval(this.memoryPressureTimer);
            this.memoryPressureTimer = null;
        }
    }

    private resolveIdleTimeoutMs(): number {
        const configured = Number(process.env.QUENDERIN_LLM_IDLE_MINUTES ?? String(HW.defaultIdleMinutes));
        if (!Number.isFinite(configured)) return HW.defaultIdleMinutes * 60 * 1000;
        // Clamp to a sane range so misconfiguration can't disable unloading forever.
        const clampedMinutes = Math.min(120, Math.max(1, Math.round(configured)));
        return clampedMinutes * 60 * 1000;
    }

    private isInferenceBusy(): boolean {
        return this.isGeneratingChat || this.isGeneratingAction;
    }

    public isCurrentlyGenerating(): { isGenerating: boolean, buffer: string } {
        return { isGenerating: this.isInferenceBusy(), buffer: this.tokenBuffer };
    }

    /** Q-292: stop the in-flight chat generation. Aborts the current prompt's signal so
     *  node-llama-cpp ends the native decode; `generalChat` then resolves gracefully with the
     *  streamed partial (a deliberate stop is not an error). No-op when nothing is generating. */
    public requestChatCancel(): void {
        if (this.chatAbort) {
            logger.log('[LLM] Chat generation cancel requested by user.');
            this.chatAbort.abort();
        }
    }

    /** Switch the active preset (persona). Resets chat session so the new system prompt takes effect. */
    public setPreset(presetId: string): void {
        const preset = getPresetById(presetId);
        if (preset.id === this.activePreset.id) return;
        this.parkedChatHistory = null;
        this.activePreset = preset;
        // Reset chat session to pick up the new system prompt
        this.disposeChatSession();
        logger.log(`[LLM] Preset switched to: ${preset.label}`);
    }

    public getActivePresetId(): string {
        return this.activePreset.id;
    }

    /** Q-615: serializes ALL native decodes. generalChat (foreground) and generateAction (the
     *  background daemon) share one model + context; two concurrent decodes corrupt the KV state. Every
     *  generation path funnels through promptWithTimeout, so one mutex here is the single chokepoint. */
    private inferenceMutex: Promise<void> = Promise.resolve();

    private async promptWithTimeout(
        session: LlamaChatSession,
        prompt: string,
        options: {
            maxTokens: number;
            temperature: number;
            onTextChunk?: (chunk: string) => void;
            /** Compiled node-llama-cpp grammar — constrains decoding to a JSON schema. */
            grammar?: any;
            /** Native chat functions (mutually exclusive with grammar per node-llama-cpp). */
            functions?: Record<string, unknown>;
            /** Repetition penalty { penalty, lastTokens } — the anti-loop guard the Swift twin ships. */
            repeatPenalty?: { penalty: number; lastTokens: number };
            /** Reasoning-token budget; chat passes { thoughtTokens: 0 } so hidden thinking can't
             *  consume the whole maxTokens cap and starve the visible answer. */
            budgets?: { thoughtTokens?: number };
        },
        timeoutMs: number,
        label: string,
        externalSignal?: AbortSignal
    ): Promise<string> {
        // A stop that arrived before we even queue: don't take the lock, just report cancelled.
        if (externalSignal?.aborted) {
            const cancelErr: NodeJS.ErrnoException = new Error(`${label} cancelled`);
            cancelErr.code = 'LLM_CANCELLED';
            throw cancelErr;
        }
        // Q-615: acquire the inference lock (queue behind any in-flight decode) BEFORE arming the
        // timeout — a decode waiting its turn must not "time out" against wall-clock spent queued. The
        // lock always releases (finally), so `await prev` never rejects. The daemon also skips-if-busy
        // upstream, so this mostly closes the narrow TOCTOU window where the foreground starts mid-check.
        const prev = this.inferenceMutex;
        let release!: () => void;
        this.inferenceMutex = new Promise<void>((r) => { release = r; });
        await prev;
        try {
            const ac = new AbortController();
            this.nativeAborts.add(ac);
            if (this.shuttingDown) ac.abort();
            const timer = setTimeout(() => ac.abort(), timeoutMs);
            // Q-292: compose an optional external cancel (user "stop chat" / agent stop) with the timeout
            // — either aborts the same native decode. Classify the abort by CAUSE: an external cancel is
            // a deliberate stop (LLM_CANCELLED, caller keeps the partial), the timer is a hang (LLM_TIMEOUT).
            const onExternalAbort = () => ac.abort();
            if (externalSignal) {
                if (externalSignal.aborted) ac.abort();   // cancelled while it was queued
                else externalSignal.addEventListener('abort', onExternalAbort, { once: true });
            }
            try {
                return await session.prompt(prompt, { ...options, signal: ac.signal });
            } catch (err: unknown) {
                if (externalSignal?.aborted) {
                    const cancelErr: NodeJS.ErrnoException = new Error(`${label} cancelled`);
                    cancelErr.code = 'LLM_CANCELLED';
                    throw cancelErr;
                }
                if (ac.signal.aborted) {
                    const timeoutErr: NodeJS.ErrnoException = new Error(`${label} timed out after ${Math.round(timeoutMs / 1000)}s`);
                    timeoutErr.code = 'LLM_TIMEOUT';
                    throw timeoutErr;
                }
                throw err;
            } finally {
                this.nativeAborts.delete(ac);
                clearTimeout(timer);
                if (externalSignal) externalSignal.removeEventListener('abort', onExternalAbort);
            }
        } finally {
            release();
        }
    }

    private async waitWithInitTimeout<T>(promise: Promise<T>, label: string): Promise<T> {
        return Promise.race([
            promise,
            new Promise<T>((_, reject) => {
                setTimeout(() => {
                    const err = new Error(`${label} timed out after ${Math.round(this.modelInitTimeoutMs / 1000)}s`) as NodeJS.ErrnoException;
                    err.code = 'LLM_INIT_TIMEOUT';
                    reject(err);
                }, this.modelInitTimeoutMs);
            })
        ]);
    }

    // ─── Model Lifecycle Methods ────────────────────────────────────────────

    /** Touch activity timer — resets the idle countdown */
    private touchActivity(): void {
        this.lastActivityTimestamp = Date.now();
        this.resetIdleTimer();
    }

    private resetIdleTimer(): void {
        if (this.idleTimer) clearTimeout(this.idleTimer);
        this.idleTimer = setTimeout(() => {
            // Q-416: also hold off while a download is in flight. Even though a download doesn't use the
            // loaded model, a download usually precedes a switch/load, so unloading here just churns RAM
            // (unload now → reload seconds later). Conservative: idle-unload only when truly idle.
            if (!this.isInferenceBusy() && !this.initPromise && !this.isDownloading && this.modelInstance) {
                logger.log(`[Lifecycle] Unloading model after ${this.idleTimeoutMs / 60000}min idle to free RAM`);
                this.unloadModel();
            }
        }, this.idleTimeoutMs);
        this.idleTimer.unref(); // Don't block process exit
    }

    /** Explicitly unload model to free RAM */
    public unloadModel(): void {
        // A caller timeout is not a native join. Keep its reservation and references until the
        // actual load settles; retrying must join that same work instead of allocating again.
        if (this.nativeLoadPending) return;
        const wasLoaded = this.modelInstance !== null;
        // Dispose the native handles BEFORE dropping the references. node-llama-cpp models/contexts
        // hold native memory that GC won't promptly reclaim, so nulling alone left the model (~GBs)
        // allocated — this "free RAM" path (incl. the idle-timer + memory-pressure auto-unload) freed
        // nothing. Capture refs, null synchronously so the service reads as unloaded, then fire-and-
        // forget dispose: session first (holds a context sequence), then context, then model.
        const model = this.modelInstance;
        const context = this.contextInstance;
        this.modelInstance = null;
        this.contextInstance = null;
        this.disposeChatSession();
        // Cached sequences belong to this context and cached grammars to this engine — a reload
        // builds fresh ones; keeping stale handles would crash the first post-reload decode.
        this.releaseAllActionCaches();
        this.grammarCache.clear();
        this.trackDisposal(context, model);
        this.initPromise = null;
        this.loadedModelId = null;
        this.activeModelEntry = null;
        this.gpuBackendUsed = 'unknown';
        this.flashAttentionActive = false;
        this.actualContextSize = 0;
        if (this.idleTimer) {
            clearTimeout(this.idleTimer);
            this.idleTimer = null;
        }
        this.stopMemoryPressureMonitor();
        if (wasLoaded) logger.log('[Lifecycle] Model unloaded');
    }

    private trackDisposal(context: any, model: any): void {
        const work = (async () => {
            try { await context?.dispose(); } finally { await model?.dispose(); }
        })();
        // Preserve a disposal failure: another model must not start against uncertain live allocations.
        this.disposal = Promise.all([this.disposal, work]).then(() => {});
        void this.disposal.catch(() => {});
    }

    /** Called only under the exclusive process lease, after every ordinary operation has joined. */
    public async releaseForSpecialist(): Promise<void> {
        if (this.generalChatSession?.getChatHistory) {
            const encoded = JSON.stringify(this.generalChatSession.getChatHistory());
            if (Buffer.byteLength(encoded) > 1024 * 1024) throw new Error('The current conversation cannot be suspended within its memory bound.');
            this.parkedChatHistory = { modelId: this.loadedModelId ?? this.activeModelId, presetId: this.activePreset.id, history: JSON.parse(encoded) };
        }
        this.unloadModel();
        await this.disposal;
    }

    public cancelNativeWork(): void {
        this.shuttingDown = true;
        this.chatAbort?.abort();
        for (const controller of this.nativeAborts) controller.abort();
    }

    /** Instance cleanup never disposes the process-global addon backend. */
    public shutdownNativeWork(): Promise<void> {
        this.cancelNativeWork();
        return this.shutdownTask ??= (async () => {
            await nativeWorkloads.joinOwner(this);
            if (this.nativeLoadPending) { try { await this.initPromise; } catch { /* load failure owns its partial handles */ } }
            // A JS init timeout can leave the actual native backend initialization running.
            while (this.nativeInitializations.size) await Promise.allSettled([...this.nativeInitializations]);
            await this.inferenceMutex;
            this.unloadModel();
            await this.disposal;
            this.unregisterWorkload();
            this.llamaEngine = null;
            if (this.idleTimer) { clearTimeout(this.idleTimer); this.idleTimer = null; }
            this.stopMemoryPressureMonitor();
        })();
    }

    /** Only production process exit may close global admission, join every owner, and free backends. */
    public async shutdown(options: { processExit?: boolean } = {}): Promise<void> {
        this.cancelNativeWork();
        if (options.processExit) {
            if (this.llamaEngine) nativeWorkloads.registerBackend(this.llamaEngine);
            await nativeWorkloads.shutdown();
        }
        await this.shutdownNativeWork();
    }

    private trackBackendInitialization<T extends { dispose(): void | Promise<void> }>(promise: Promise<T>): Promise<T> {
        const tracked = promise.then(backend => { nativeWorkloads.registerBackend(backend); return backend; });
        this.nativeInitializations.add(tracked);
        void tracked.then(() => { this.nativeInitializations.delete(tracked); }, () => { this.nativeInitializations.delete(tracked); });
        return tracked;
    }

    /** Switch to a specific model by ID. Unloads current model if different. */
    public async switchModel(modelId: string): Promise<void> {
        const release = nativeWorkloads.beginOrdinary(this);
        try { return await this.switchModelWithLease(modelId); } finally { release(); }
    }
    private async switchModelWithLease(modelId: string): Promise<void> {
        const entry = MODEL_CATALOG.find((m) => m.id === modelId);
        if (!entry) {
            throw new Error(`Unknown model id: ${modelId}`);
        }
        await this.assertModelRuntime(entry);
        const filePath = modelPath(modelId);
        if (!fs.existsSync(filePath)) {
            const err = new Error('MODEL_MISSING');
            (err as NodeJS.ErrnoException).code = 'MODEL_MISSING';
            throw err;
        }
        if (this.isInferenceBusy() || this.nativeLoadPending) {
            // Q-283: THROW, don't silently return — a bare return let the switch route report
            // "Model switched." while nothing changed. The REST caller (the one switch path since
            // the WS twin was removed) already catches switchModel throws, so this reports failure.
            logger.warn('[Lifecycle] Cannot switch model during active generation');
            const err = new Error('INFERENCE_BUSY');
            (err as NodeJS.ErrnoException).code = 'INFERENCE_BUSY';
            throw err;
        }
        if (this.loadedModelId === modelId) {
            this.activeModelId = modelId;
            logger.log(`[Lifecycle] Model ${modelId} already loaded, skipping`);
            return;
        }
        await this.assertModelFileIdentity(entry, filePath,
            requiresPrismRuntime(entry) ? await this.getPrismRuntime() : undefined);
        this.unloadModel();
        this.activeModelId = modelId;
        // Pre-warm the model
        await this.getModelAndContext();
    }

    public getModelLifecycleInfo(): { loadedModelId: string | null; loadedSinceMs: number; isGenerating: boolean; gpuBackend: string; flashAttention: boolean } {
        return {
            loadedModelId: this.loadedModelId,
            loadedSinceMs: this.modelLoadTimestamp > 0 ? Date.now() - this.modelLoadTimestamp : 0,
            isGenerating: this.isInferenceBusy(),
            gpuBackend: this.gpuBackendUsed,
            flashAttention: this.flashAttentionActive,
        };
    }

    private getPrismRuntime(): Promise<NodeLlamaRuntime | undefined> {
        if (!this.prismRuntimeProbe) {
            this.prismRuntimeProbe = (async () => {
                if (!_llamaBindings) return undefined;
                try {
                    // dryRun does not initialize a backend or allocate model memory. It implies
                    // build:'never'; disabling prebuilts prevents a silent stock-runtime fallback.
                    const probe = await _llamaBindings.getLlama({
                        dryRun: true,
                        build: 'never',
                        // The shipped Prism addon is built with --gpu false. Resolve that
                        // exact CPU build even when GPU addons/prebuilts are also installed.
                        gpu: false,
                        usePrebuiltBinaries: false,
                        skipDownload: true,
                        progressLogs: false,
                        logLevel: _llamaBindings.LlamaLogLevel.disabled,
                    });
                    if (!isPrismRuntime(probe) || !hasPrismTensorTypes(probe)) return undefined;
                    return runtimeCapabilities(probe);
                } catch {
                    return undefined;
                }
            })();
        }
        return this.prismRuntimeProbe;
    }

    public async checkModelRuntime(entry: RuntimeModelDescriptor): Promise<ModelRuntimeCompatibility> {
        const runtime = requiresPrismRuntime(entry) ? await this.getPrismRuntime() : undefined;
        return getModelRuntimeCompatibility(entry, runtime);
    }

    public async checkModelMemory(entry: ModelEntry): Promise<MemoryCheckResult> {
        const runtime = requiresPrismRuntime(entry) ? await this.getPrismRuntime() : undefined;
        return checkMemoryForModel(entry, runtime);
    }

    private assertPrismMemory(entry: ModelEntry, runtime?: NodeLlamaRuntime): void {
        if (!requiresPrismRuntime(entry)) return;
        const memory = checkMemoryForModel(entry, runtime);
        if (!memory.canLoad) {
            this.emit('action_required', {
                code: 'MODEL_MEMORY_UNSAFE',
                title: 'Insufficient Memory for Experimental Model',
                message: memory.message,
            });
            const error = new Error(memory.message) as NodeJS.ErrnoException;
            error.code = 'MODEL_MEMORY_UNSAFE';
            throw error;
        }
    }

    private async assertModelRuntime(entry: ModelEntry): Promise<void> {
        const runtime = requiresPrismRuntime(entry) ? await this.getPrismRuntime() : undefined;
        const compatibility = getModelRuntimeCompatibility(entry, runtime);
        if (!compatibility.canLoad) {
            this.emit('action_required', {
                code: 'MODEL_RUNTIME_UNSUPPORTED',
                title: 'Experimental Runtime Required',
                message: compatibility.message,
            });
            throw modelRuntimeError(compatibility);
        }
        this.assertPrismMemory(entry, runtime);
    }

    private async assertModelFileIdentity(entry: ModelEntry, filePath: string, runtime?: NodeLlamaRuntime): Promise<void> {
        if ('artifacts' in entry) await verifyMultipartModel(entry, filePath);
        else if (/-\d{5}-of-\d{5}\.gguf$/i.test(entry.filename)) throw new Error('A complete multipart catalog manifest is required.');
        const identity = await readGgufModelIdentity(filePath);
        const compatibility = getModelRuntimeCompatibility({ ...entry, ...identity }, runtime);
        if (!compatibility.canLoad) throw modelRuntimeError(compatibility);
    }

    public async getModelAndContext() {
        const release = nativeWorkloads.beginOrdinary(this);
        try { return await this.getModelAndContextWithLease(); } finally { release(); }
    }
    private async getModelAndContextWithLease() {
        if (this.shuttingDown) throw new Error('The local engine is shutting down.');
        await this.disposal;
        this.touchActivity();

        if (this.modelInstance && this.contextInstance) {
            return { model: this.modelInstance, context: this.contextInstance };
        }

        // Mutex lock to prevent multiple concurrent requests from crashing memory
        if (this.initPromise) {
            return await this.waitWithInitTimeout(this.initPromise, 'Model initialization');
        }

        const releaseLoad = nativeWorkloads.beginOrdinary(this);
        this.nativeLoadPending = true;
        const promise = (async () => {
            // Hoisted so the catch can dispose a partially-built load (model loaded, context failed).
            let model: LlamaModel | undefined;
            let context: LlamaContext | undefined;
            try {
                const needsPrism = MODEL_CATALOG.some(entry =>
                    requiresPrismRuntime(entry) && fs.existsSync(modelPath(entry.id)));
                const runtime = needsPrism ? await this.getPrismRuntime() : undefined;
                // Use pinned activeModelId when its file exists; otherwise auto-select
                const selected = selectPinnedOrBestModel(
                    this.activeModelId,
                    this.currentSettings.memorySafetyEnabled,
                    runtime,
                );

                if (!selected) {
                    // No model file exists on disk at all — ask user to download one
                    const freeRamGb = availableMemBytes() / (1024 ** 3);
                    const totalRamGb = os.totalmem() / (1024 ** 3);
                    const compatibleModels = MODEL_CATALOG.filter(m => getModelRuntimeCompatibility(m, runtime).canLoad
                        && (!requiresPrismRuntime(m) || checkMemoryForModel(m, runtime).canLoad));
                    const fittingModels = compatibleModels.filter(m => {
                        const used = totalRamGb - freeRamGb;
                        return (m.ramGb + used) <= totalRamGb * 0.85;
                    });
                    const err = new Error("MODEL_MISSING") as TaggedError;
                    err.code = "MODEL_MISSING";
                    err.fittingModels = fittingModels.length > 0 ? fittingModels : compatibleModels;
                    throw err;
                }

                // Graceful degradation: model exists but doesn't fit the RAM budget.
                // Load it anyway with minimal context and warn the user, rather than
                // showing an impassable OOM wall. The OS will swap if needed — slow
                // but functional, which is better than a dead app.
                if (selected.degraded) {
                    logger.warn(`[Lifecycle] RAM is tight — loading ${selected.entry.label} in degraded mode (minimal context). Performance may be reduced.`);
                }

                // Keep an explicitly pinned id; only update when auto-selecting
                if (selected.entry.id !== this.activeModelId) {
                    this.activeModelId = selected.entry.id;
                }
                this.activeModelEntry = selected.entry;
                logger.log(`[LLM] Loading ${selected.entry.label} (~${selected.entry.ramGb}GB RAM)`);

                const freeRamGb = availableMemBytes() / (1024 ** 3);
                if (freeRamGb < 1.0) {
                    logger.warn(`[System] Warning: Only ${freeRamGb.toFixed(1)}GB RAM free. System may be slow.`);
                }

                // ─── Situation-aware context sizing ─────────────────────────
                // Considers model size (1B/3B/8B caps), available RAM, user
                // preference, and degraded state — picks the smartest value
                // so users never have to fiddle with settings manually.
                const effectiveCtx = resolveContextForSituation(
                    selected.entry, freeRamGb,
                    this.currentSettings.contextSize, selected.degraded
                );
                if (effectiveCtx < this.currentSettings.contextSize) {
                    logger.log(`[LLM] Context auto-tuned: ${this.currentSettings.contextSize} → ${effectiveCtx} (model=${selected.entry.paramsBillions}B, freeRAM=${freeRamGb.toFixed(1)}GB${selected.degraded ? ', degraded' : ''})`);
                }

                // --- GPU / Context Fallback Chain ---
                // • Flash attention: drastically reduces KV cache memory + speeds up inference
                // • GPU layers: offload to Metal/CUDA when available, CPU-only on embedded/Pi
                // • Fallback chain: effectiveCtx → halved → contextFloor
                // • All timeouts scaled by HW.timeoutMultiplier for slow ARM boards
                // Check if node-llama-cpp is available on this architecture
                if (!_llamaBindings) {
                    const err = new Error(
                        `LLM bindings not available on ${process.arch}/${process.platform}. ` +
                        (_llamaImportError ? _llamaImportError.message : 'Unknown import failure.')
                    ) as NodeJS.ErrnoException;
                    err.code = 'LLM_BINDINGS_UNAVAILABLE';
                    this.emit('action_required', {
                        code: 'LLM_BINDINGS_UNAVAILABLE',
                        title: 'Platform Not Supported for Local AI',
                        message: `Local LLM inference requires x86_64 or arm64 architecture. ` +
                            `Your system is ${process.arch}/${process.platform}. ` +
                            `The dashboard UI still works, but chat and agent features are disabled.`,
                    });
                    throw err;
                }

                const { getLlama: getLlamaFn, LlamaLogLevel: LogLevel } = _llamaBindings;
                // Read only local metadata before any model weights reach the native loader.
                // A catalog filename or alias cannot turn Beam/Hy-Memory into ordinary chat.
                await this.assertModelFileIdentity(selected.entry, selected.path, runtime);
                const llamaInitTimeout = Math.round(30_000 * HW.timeoutMultiplier);

                // ─── 1. Initialize llama engine with GPU fallback ────────────
                // Specify gpu explicitly so Metal/CUDA/Vulkan is negotiated
                // properly. If GPU backend hangs (shader compilation on new
                // chips like M4 Pro), fall back to CPU-only.
                let llama: any;
                const gpuMode = HW.tryGpuOffload ? "auto" : false;
                let resolvedGpuBackend = gpuMode === false ? 'cpu' : 'gpu';
                if (requiresPrismRuntime(selected.entry)) {
                    // Use the exact addon whose capability was probed. A rebuild/replacement
                    // between probe and load must fail before its GGUF parser sees the file.
                    llama = await this.trackBackendInitialization(getLlamaFn({
                        build: 'never',
                        gpu: false,
                        usePrebuiltBinaries: false,
                        skipDownload: true,
                        progressLogs: false,
                        logLevel: LogLevel.disabled,
                    }));
                    const capability = runtimeCapabilities(llama);
                    const compatibility = getModelRuntimeCompatibility(selected.entry, capability);
                    if (!compatibility.canLoad || !hasPrismTensorTypes(llama)) {
                        throw modelRuntimeError(compatibility.canLoad ? {
                            canLoad: false,
                            message: 'The installed Prism desktop addon is missing the required PQ2_0/PTQ1_0 native tensor types. Rebuild the pinned Prism runtime before selecting this model.',
                        } : compatibility);
                    }
                    // Recheck current RAM after backend initialization, before allocating weights.
                    this.assertPrismMemory(selected.entry, capability);
                    resolvedGpuBackend = llama.gpu === false ? 'cpu' : String(llama.gpu ?? 'gpu');
                } else try {
                    llama = await Promise.race([
                        this.trackBackendInitialization(getLlamaFn({ logLevel: LogLevel.disabled, gpu: gpuMode })),
                        new Promise((_, reject) => setTimeout(() => {
                            reject(new Error(`Llama engine init (gpu=${gpuMode}) timed out after ${llamaInitTimeout / 1000}s`));
                        }, llamaInitTimeout))
                    ]) as any;
                    resolvedGpuBackend = gpuMode === false ? 'cpu' : (HW.platform === 'darwin' ? 'metal' : 'gpu');
                } catch (initErr) {
                    if (gpuMode !== false && !this.shuttingDown) {
                        logger.warn('[LLM] GPU backend init failed, retrying CPU-only:', initErr instanceof Error ? initErr.message : initErr);
                        llama = await Promise.race([
                            this.trackBackendInitialization(getLlamaFn({ logLevel: LogLevel.disabled, gpu: false })),
                            new Promise((_, reject) => setTimeout(() => {
                                reject(new Error(`Llama engine init (CPU-only) timed out after ${llamaInitTimeout / 1000}s`));
                            }, llamaInitTimeout))
                        ]) as any;
                        resolvedGpuBackend = 'cpu-fallback';
                        logger.log('[LLM] Llama engine initialized (CPU-only fallback)');
                    } else {
                        throw initErr;
                    }
                }
                this.llamaEngine = llama;   // retained for shutdown()'s device dispose
                nativeWorkloads.registerBackend(llama);

                // ─── 2. Load model with GPU offload + AbortController ────────
                // AbortController actually cancels native operations (unlike
                // bare Promise.race which only races the JS promise).
                const loadWithGpu = (gpuLayers: "max" | number) => {
                    if (this.shuttingDown) return Promise.reject(new Error('The local engine is shutting down.'));
                    const ac = new AbortController();
                    this.nativeAborts.add(ac);
                    const timer = setTimeout(() => ac.abort(), this.modelInitTimeoutMs);
                    return llama.loadModel({
                        modelPath: selected.path,
                        ...(gpuLayers === "max" ? { gpuLayers: "max" as any } : { gpuLayers }),
                        loadSignal: ac.signal,
                    }).finally(() => { clearTimeout(timer); this.nativeAborts.delete(ac); });
                };

                // A file bigger than the GPU can safely wire (paged MoE, e.g. the 13 GB
                // 35B-A3B) must go straight to CPU + mmap so the OS page cache streams the
                // experts — trying GPU first would thrash/fail slowly and then fall back anyway.
                const fileSizeGb = (() => {
                    try { return fs.statSync(selected.path).size / 1e9; } catch { return 0; }
                })();
                const fitsGpu = gpuOffloadFits(fileSizeGb, os.totalmem() / (1024 ** 3));
                const tryModelGpuOffload = HW.tryGpuOffload && !requiresPrismRuntime(selected.entry);
                if (tryModelGpuOffload && fitsGpu) {
                    try {
                        model = await loadWithGpu("max");
                        logger.log('[LLM] Model loaded with GPU offload (max layers)');
                    } catch (gpuErr) {
                        logger.warn('[LLM] GPU offload failed, falling back to CPU-only:', gpuErr instanceof Error ? gpuErr.message : gpuErr);
                        model = await loadWithGpu(0);
                        logger.log('[LLM] Model loaded in CPU-only mode');
                    }
                } else if (tryModelGpuOffload) {
                    // GPU exists, but the weights exceed the safe offload budget.
                    model = await loadWithGpu(0);
                    logger.log(`[LLM] Model loaded in CPU-only mode (${fileSizeGb.toFixed(1)} GB weights exceed GPU offload budget — OS page cache streams them)`);
                } else {
                    // Embedded/headless ARM or the deterministic CPU Prism addon.
                    model = await loadWithGpu(0);
                    logger.log(`[LLM] Model loaded in CPU-only mode (${requiresPrismRuntime(selected.entry) ? 'Prism runtime' : 'embedded hardware'})`);
                }

                // Thread count: limit to cpuCores-1 on low-core devices to avoid
                // starving the OS/Node event loop. Override via QUENDERIN_THREAD_COUNT.
                const envThreads = Number(process.env.QUENDERIN_THREAD_COUNT);
                const autoThreads = HW.cpuCores <= 2 ? 1
                    : HW.cpuCores <= 4 ? HW.cpuCores - 1
                    : Math.min(HW.cpuCores - 2, 8);
                const threads = Number.isFinite(envThreads) && envThreads >= 1
                    ? envThreads : autoThreads;
                logger.log(`[LLM] Using ${threads} inference threads (${HW.cpuCores} cores detected)`);

                // ─── 3. Create context with flash-attention + size fallback ──
                // Flash attention may not work on all GPU generations (e.g. new
                // Metal chips). If it fails, retry without it before reducing
                // context size. AbortController ensures hangs are cancelled.
                let useFlashAttention = true;

                const tryCreateContext = (ctxSize: number, flash: boolean) => {
                    if (this.shuttingDown) return Promise.reject(new Error('The local engine is shutting down.'));
                    const ac = new AbortController();
                    this.nativeAborts.add(ac);
                    const timer = setTimeout(() => ac.abort(), this.modelInitTimeoutMs);
                    return model.createContext({
                        contextSize: ctxSize,
                        flashAttention: flash,
                        threads,
                        createSignal: ac.signal,
                    }).finally(() => { clearTimeout(timer); this.nativeAborts.delete(ac); });
                };

                const requestedCtx = effectiveCtx;
                // Q-415: the "Context ready" log must report the ACTUAL context that was created — the
                // fallbacks below can HALVE it (or drop to the floor), and logging the requested size hid
                // that a session is running with far less context than asked for (a real OOM/perf debug clue).
                let actualCtx = requestedCtx;
                try {
                    // Attempt 1: full context + flash attention
                    context = await tryCreateContext(requestedCtx, true);
                } catch (ctxErr1) {
                    // Flash attention might not be supported on this GPU —
                    // retry same size without it before reducing context.
                    logger.warn(`[LLM] Context creation failed at ${requestedCtx} (flash=on): ${ctxErr1 instanceof Error ? ctxErr1.message : ctxErr1}`);
                    try {
                        context = await tryCreateContext(requestedCtx, false);
                        useFlashAttention = false;
                        logger.log(`[LLM] Context created without flash attention at ${requestedCtx}`);
                    } catch {
                        const reducedCtx = Math.max(Math.floor(requestedCtx / 2), HW.contextFloor);
                        logger.warn(`[LLM] Context creation failed at ${requestedCtx}, trying ${reducedCtx}...`);
                        try {
                            // Attempt 3: halved context, no flash attention
                            context = await tryCreateContext(reducedCtx, false);
                            actualCtx = reducedCtx;
                            useFlashAttention = false;
                        } catch {
                            logger.warn(`[LLM] Reduced context failed, trying minimal (${HW.contextFloor})...`);
                            // Attempt 4: hardware floor, no flash attention
                            context = await tryCreateContext(HW.contextFloor, false);
                            actualCtx = HW.contextFloor;
                            useFlashAttention = false;
                        }
                    }
                }
                // Report what flash-attention ACTUALLY is, not what we asked for. createContext
                // accepts `flashAttention: true` and then SILENTLY turns it off (a warning, no throw)
                // when the model/arch can't support it (Grok, Gemma2, unsupported head dims) — so
                // `useFlashAttention` (our request) lied "on" while the real decode ran without it,
                // masking a ~15-25% throughput gap in every diagnostic. The context exposes the real
                // state via `.flashAttention`; trust that, and keep the request as the fallback for a
                // binding old enough not to have the getter.
                const modelSupportsFlash = typeof (model as any)?.flashAttentionSupported === 'boolean'
                    ? (model as any).flashAttentionSupported : undefined;
                const ctxFlash = (context as any)?.flashAttention;
                const actualFlashAttention = typeof ctxFlash === 'boolean' ? ctxFlash : useFlashAttention;
                if (useFlashAttention && !actualFlashAttention) {
                    logger.warn(`[LLM] Flash attention was requested but the model does not support it${modelSupportsFlash === false ? ' (flashAttentionSupported=false)' : ''} — decode runs without it.`);
                }
                const ctxNote = actualCtx === requestedCtx ? `${actualCtx}` : `${actualCtx} (requested ${requestedCtx})`;
                logger.log(`[LLM] Context ready: ${ctxNote} tokens, flashAttention=${actualFlashAttention ? 'on' : 'off'}${modelSupportsFlash === false ? ' (unsupported by model)' : ''}, gpu=${resolvedGpuBackend}, tier=${HW.tier}`);
                this.modelInstance = model;
                this.contextInstance = context;
                this.loadedModelId = selected.entry.id;
                this.modelLoadTimestamp = Date.now();
                this.gpuBackendUsed = resolvedGpuBackend;
                this.flashAttentionActive = actualFlashAttention;
                this.actualContextSize = actualCtx;
                this.startMemoryPressureMonitor();
                return { model, context };
            } catch (error: unknown) {
                const code = errCode(error);
                const isModelMissing = code === "MODEL_MISSING" || code === "ENOENT";

                if (isModelMissing) {
                    this.emit('action_required', {
                        code: 'MODEL_MISSING',
                        title: 'No AI Model Installed',
                        message: 'Download one of the models below to get started. Smaller models use less RAM.',
                        autoTrigger: 'downloadModel',
                        fittingModels: (error as Record<string, unknown>).fittingModels ?? MODEL_CATALOG
                    });
                } else {
                    logger.error("Failed to load LLaMA model:", error);
                }

                // Dispose any native handle built before the failure. A model that loaded (~GBs) but
                // whose context creation then failed (the OOM fallback chain above) would otherwise leak
                // until process exit, compounding on every retry on exactly the memory-tight devices that
                // hit this path. Both are undefined for the pre-load throws (MODEL_MISSING/bindings) — no-op.
                this.trackDisposal(context, model);
                this.initPromise = null;
                throw error;
            }
        })();
        // A caller timeout must not release the process memory lease while native loading continues.
        const loadSettled = () => { this.nativeLoadPending = false; releaseLoad(); };
        void promise.then(loadSettled, loadSettled);

        this.initPromise = promise;
        return await this.waitWithInitTimeout(promise, 'Model initialization');
    }

    /** Cross-platform disk space check — best-effort, non-fatal on failure */
    private async checkDiskSpace(dirPath: string, requiredBytes: number): Promise<{ ok: boolean; message: string }> {
        try {
            if (process.platform === 'win32') {
                const { execSync } = await import('child_process');
                const drive = path.resolve(dirPath).charAt(0);
                let freeBytes: number | null = null;

                // Sanitize drive letter — must be a single A-Z character to prevent injection
                const sanitizedDrive = drive.match(/^[A-Za-z]$/) ? drive : 'C';

                // PowerShell: works on Windows 8+ and is the only option on Windows 11 22H2+
                // where wmic has been removed.
                try {
                    const psOut = execSync(
                        `powershell -NoProfile -Command "(Get-PSDrive -Name ${sanitizedDrive}).Free"`,
                        { encoding: 'utf8', timeout: 5000 }
                    );
                    const parsed = parseInt(psOut.trim(), 10);
                    if (Number.isFinite(parsed) && parsed >= 0) freeBytes = parsed;
                } catch { /* PowerShell unavailable — try wmic */ }

                // Legacy fallback: wmic works on Windows 7–10 (removed in Win11 22H2)
                if (freeBytes === null) {
                    try {
                        const wmicOut = execSync(`wmic logicaldisk where "DeviceID='${sanitizedDrive}:'" get FreeSpace /value`, { encoding: 'utf8', timeout: 5000 });
                        const match = wmicOut.match(/FreeSpace=(\d+)/);
                        if (match) freeBytes = parseInt(match[1], 10);
                    } catch { /* wmic also unavailable — skip disk check */ }
                }

                if (freeBytes !== null && freeBytes < requiredBytes) {
                    return { ok: false, message: `Only ${(freeBytes / (1024 ** 3)).toFixed(1)}GB free on ${drive}: drive, need ~${(requiredBytes / (1024 ** 3)).toFixed(1)}GB. Free up disk space.` };
                }
            } else {
                // Unix: df on the directory. execFileSync (no shell) so a home dir containing " or $(
                // can't break quoting / inject a subshell — the path derives from os.homedir().
                const { execFileSync } = await import('child_process');
                const out = execFileSync('df', ['-k', dirPath], { encoding: 'utf8', timeout: 5000 });
                const lines = out.trim().split('\n');
                const parts = (lines[lines.length - 1] || '').trim().split(/\s+/);
                // df -k output: Filesystem 1K-blocks Used Available Use% Mounted
                const availKb = parseInt(parts[3], 10);
                if (!isNaN(availKb)) {
                    const freeBytes = availKb * 1024;
                    if (freeBytes < requiredBytes) {
                        return { ok: false, message: `Only ${(freeBytes / (1024 ** 3)).toFixed(1)}GB free disk space, need ~${(requiredBytes / (1024 ** 3)).toFixed(1)}GB. Free up space before downloading.` };
                    }
                }
            }
        } catch {
            // Non-fatal — disk check failed, proceed anyway
        }
        return { ok: true, message: '' };
    }

    public async downloadModel(modelId?: string): Promise<void> {
        const entry = MODEL_CATALOG.find(m => m.id === (modelId ?? MODEL_CATALOG[0].id)) ?? MODEL_CATALOG[0];
        await this.assertModelRuntime(entry);
        if (this.isDownloading) {
            // Q-408: only ONE download runs at a time (a single slot). Don't THROW here — the common
            // case is a benign double-trigger (double-click / auto + manual) that callers shouldn't have
            // to catch — but don't drop it SILENTLY either: log it so a genuinely-different queued
            // request that never starts is diagnosable (cf. Q-293's visible-not-silent backpressure).
            logger.warn(`[LLM] Download already in progress — ignoring concurrent request for "${modelId ?? 'default'}".`);
            return;
        }
        this.isDownloading = true;
        if ('artifacts' in entry) {
            try {
                await installMultipartModel(entry, path.dirname(modelPath(entry.id)), fraction =>
                    this.emit('model_download_progress', { progress: Math.min(100, fraction * 100), modelId: entry.id }));
                this.emit('model_download_progress', { progress: 100, modelId: entry.id });
            } finally { this.isDownloading = false; }
            return;
        }

        const url = entry.url;
        const dest = modelPath(entry.id);
        const dir = path.dirname(dest);
        const metaPath = dest + '.download.json';
        // bug hunt r-uc #1/#5: stream to a `.part` staging file and rename to `dest` ONLY after
        // integrity verification passes. The model LOAD path (selectBestModel) picks a model purely
        // by `fs.existsSync(dest)` with NO integrity check, so if the download wrote straight to
        // `dest`, a concurrent chat — or the next launch's fast path — could hand a torn/partial GGUF
        // to node-llama-cpp's native parser (crash / memory-corruption→RCE surface). With staging,
        // `dest` is never present until the bytes are complete AND verified.
        const staging = dest + '.part';

        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }

        logger.log(`[LLM] Downloading ${entry.label} from HuggingFace...`);

        // Check if already downloaded — but a pre-existing file is still UNTRUSTED (C3): one
        // planted before first launch, corrupted in place, or substituted must not be handed to
        // node-llama-cpp's GGUF parser unverified. Verify it; on failure delete it and fall
        // through to a fresh download rather than re-accepting a bad file on every launch.
        if (fs.existsSync(dest)) {
            const stats = await fs.promises.stat(dest);
            if (stats.size > 100_000_000) { // 100MB sanity check
                try {
                    await verifyModelIntegrity(dest, entry.sha256);
                    this.emit('model_download_progress', { progress: 100, modelId: entry.id });
                    this.isDownloading = false;
                    // Clean up stale metadata
                    if (fs.existsSync(metaPath)) fs.unlinkSync(metaPath);
                    return;
                } catch (verifyError) {
                    logger.warn(`[LLM] Pre-existing ${entry.filename} failed integrity check (${String(verifyError)}); deleting and re-downloading.`);
                    try { fs.unlinkSync(dest); } catch { /* ignore */ }
                    try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
                    // fall through to a fresh download
                }
            }
        }

        // ─── Disk Space Check ─────────────────────────────────────────
        // Estimate required space: model file + 500MB buffer for OS/other ops
        let diskLowMessage: string | null = null;
        try {
            const estimatedBytes = 'downloadBytes' in entry
                ? entry.downloadBytes : entry.ramGb * (1024 ** 3);
            const bufferBytes = 500 * (1024 ** 2); // 500 MB buffer
            const { availableMemBytes: getAvail } = await import('../utils/memory.js');
            // Use free memory as a proxy for whether the system has headroom
            // (disk space check via statfs would be ideal, but cross-platform is tricky)
            const freeRam = getAvail();
            if (freeRam < estimatedBytes * 0.5) {
                logger.warn(`[LLM] Low system memory (${(freeRam / (1024 ** 3)).toFixed(1)}GB free). Download may cause swapping.`);
            }
            // Check disk space on the target directory. Capture the result but DON'T abort inside
            // this try — the catch is for the check ITSELF failing (can't stat), which stays non-fatal.
            const diskCheck = await this.checkDiskSpace(dir, estimatedBytes + bufferBytes);
            if (!diskCheck.ok) diskLowMessage = diskCheck.message;
        } catch {
            // Non-fatal — the disk CHECK failed (not the same as "definitely low"); proceed.
        }
        if (diskLowMessage) {
            // Q-287: a definitive low-disk result must ABORT — previously it only emitted the event
            // and fell through, downloading multiple GB into a low-disk condition.
            logger.warn(`[LLM] ${diskLowMessage}`);
            this.emit('action_required', { code: 'DISK_SPACE_LOW', title: 'Insufficient Disk Space', message: diskLowMessage });
            const err = new Error(diskLowMessage);
            (err as NodeJS.ErrnoException).code = 'DISK_SPACE_LOW';
            throw err;
        }

        try {
            // ─── Download Resume Support ────────────────────────────────────
            // Check for partial download + metadata from a previous interrupted attempt
            let receivedBytes = 0;
            const headers: Record<string, string> = {};

            if (fs.existsSync(staging) && fs.existsSync(metaPath)) {
                try {
                    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf-8'));
                    const partialStats = fs.statSync(staging);
                    // Only resume if metadata matches and partial file is substantial
                    if (meta.modelId === entry.id && partialStats.size > 0 && meta.totalBytes > 0) {
                        receivedBytes = partialStats.size;
                        headers['Range'] = `bytes=${receivedBytes}-`;
                        logger.log(`[LLM] Resuming download from ${(receivedBytes / (1024 ** 2)).toFixed(1)}MB`);
                    }
                } catch {
                    // Corrupted metadata — start fresh
                    receivedBytes = 0;
                }
            }

            // ─── Parallel ranged download (fresh downloads only) ─────────────
            // One TCP stream is capped by RTT x window; N concurrent range requests use the pipe.
            // Returns null (→ single-stream path below) when the server doesn't honor ranges or the
            // size is unknown, so correctness never depends on the CDN.
            if (receivedBytes === 0) {
                const parallelTotal = await this.downloadParallel(url, staging, entry);
                if (parallelTotal !== null) {
                    try {
                        await verifyModelIntegrity(staging, entry.sha256, parallelTotal);
                    } catch (verifyError) {
                        try { fs.unlinkSync(staging); } catch { /* ignore */ }
                        try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
                        throw verifyError;
                    }
                    fs.renameSync(staging, dest);
                    if (fs.existsSync(metaPath)) fs.unlinkSync(metaPath);
                    this.isDownloading = false;
                    return;
                }
            }

            // Fetch with timeout — prevent hanging on slow/broken connections
            // HTTP proxy support: respect HTTP_PROXY / HTTPS_PROXY env vars
            // (Node.js 18+ native fetch doesn't auto-use proxies, so we log a hint)
            const proxyUrl = process.env.HTTPS_PROXY || process.env.HTTP_PROXY || process.env.https_proxy || process.env.http_proxy;
            if (proxyUrl) {
                logger.log(`[LLM] HTTP proxy detected: ${proxyUrl} — native fetch may not use it automatically. Consider using 'global-agent' or 'undici' ProxyAgent if downloads fail.`);
            }

            const fetchTimeoutMs = Math.round(60_000 * HW.timeoutMultiplier);
            const controller = new AbortController();
            const fetchTimer = setTimeout(() => controller.abort(), fetchTimeoutMs);

            let response: Response;
            try {
                response = await fetch(url, { headers, signal: controller.signal });
            } finally {
                clearTimeout(fetchTimer);
            }

            if (!response.ok && response.status !== 206) {
                throw new Error(`Failed to download: ${response.status} ${response.statusText}`);
            }

            if (!response.body) {
                throw new Error("Readable stream not found in fetch response");
            }

            // Validate the resume response before trusting the byte accounting (H9). The
            // restart/resume/discard decision is pure logic, unit-tested in modelDownloadPlan.ts;
            // here we only carry out the fs side effects it prescribes.
            const contentLength = Number(response.headers.get('content-length')) || 0;
            const writePlan = planDownloadWrite({
                partialBytes: receivedBytes,
                status: response.status,
                contentRange: response.headers.get('content-range'),
                contentLength,
            });
            if (writePlan.action === 'discard') {
                try { fs.unlinkSync(staging); } catch { /* ignore */ }
                try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
                throw new Error(writePlan.discardReason);
            }
            receivedBytes = writePlan.writeOffset;
            const totalBytes = writePlan.totalBytes;

            // Persist download metadata for resume capability
            fs.writeFileSync(metaPath, JSON.stringify({ modelId: entry.id, totalBytes, startedAt: new Date().toISOString() }));

            let lastEmittedProgress = -1;
            const fileStream = fs.createWriteStream(staging, writePlan.append ? { flags: 'a' } : undefined);
            // A write error (e.g. ENOSPC — realistic mid-download for a multi-GB model on a tight disk)
            // emits 'error' on fileStream. Capture it so it surfaces as a thrown error the catch below
            // handles, instead of an unhandled 'error' event → uncaught exception → process exit. The
            // drain/end waits also resolve on 'error' so they can't hang once the stream is broken.
            // All additions are inert on the happy path (no error → streamError stays null).
            let streamError: Error | null = null;
            fileStream.on('error', (e) => { streamError = e; });

            try {
                const reader = response.body.getReader();

                while (true) {
                    if (streamError) throw streamError;
                    const { done, value } = await reader.read();

                    if (done) {
                        break;
                    }

                    receivedBytes += value.length;
                    if (totalBytes > 0) {
                        const progress = Math.round((receivedBytes / totalBytes) * 100);
                        if (progress !== lastEmittedProgress) {
                            this.emit('model_download_progress', { progress, modelId: entry.id });
                            lastEmittedProgress = progress;
                        }
                    }

                    // Respect backpressure so we don't buffer the whole file in memory
                    const canContinue = fileStream.write(value);
                    if (!canContinue) {
                        await new Promise<void>(resolve => {
                            fileStream.once('drain', resolve);
                            fileStream.once('error', () => resolve());
                        });
                    }
                }

                await new Promise<void>(resolve => {
                    fileStream.end(() => resolve());
                    fileStream.once('error', () => resolve());
                });
                if (streamError) throw streamError;
            } finally {
                // Free the OS file handle on every path; destroy() is idempotent + safe after end().
                fileStream.destroy();
            }

            // ─── Integrity verification (C3) ────────────────────────────────
            // The bytes are in `staging` but unverified: a TLS-MITM, poisoned mirror, or truncated
            // transfer could have substituted/corrupted them before they reach node-llama-cpp's GGUF
            // parser (memory-corruption→RCE CVEs). Check the GGUF magic header, the exact byte size
            // (catches a header-valid truncation even with no pinned sha — r-uc #5), and, when the
            // catalog pins one, the full-file SHA-256. On failure delete the STAGING file — a
            // tampered/corrupt result must NOT be kept for resume (resume would append to a poisoned
            // partial). `dest` is never written until this passes.
            try {
                await verifyModelIntegrity(staging, entry.sha256, totalBytes);
            } catch (verifyError) {
                try { fs.unlinkSync(staging); } catch { /* ignore */ }
                try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
                throw verifyError;
            }

            // Verified & complete → atomically publish to the real path (rename within one dir is
            // atomic), so the load path only ever sees a whole, checked file.
            fs.renameSync(staging, dest);

            // Clean up download metadata on success
            if (fs.existsSync(metaPath)) fs.unlinkSync(metaPath);

            this.isDownloading = false;

        } catch (error) {
            logger.error("Model download pipeline failed:", error);
            // DON'T delete partial file — keep it for resume on next attempt
            // But do keep the metadata file so we can resume
            this.isDownloading = false;
            throw error;
        }
    }

    /**
     * Fresh-download parallel path: probe range support, then fetch N disjoint segments over
     * concurrent connections into one pre-sized staging file. Returns the total size on success,
     * or null to fall back to the single-stream path (no range support / unknown size / too small).
     */
    private async downloadParallel(url: string, staging: string, entry: ModelEntry): Promise<number | null> {
        let total: number | null = null;
        try {
            const probe = await fetch(url, { headers: { Range: "bytes=0-0" } });
            if (probe.status === 206) total = parseContentRangeTotal(probe.headers.get("content-range"));
            try { await probe.body?.cancel(); } catch { /* ignore */ }
        } catch {
            return null;
        }
        if (total === null || total <= 0) return null;

        const count = downloadConnectionCount(total, false);
        if (count <= 1) return null;   // small file: not worth fanning out

        const totalBytes = total;
        const segments = planDownloadSegments(totalBytes, count);
        const handle = await fs.promises.open(staging, "w");
        const state = { received: 0, lastPct: -1 };
        try {
            await Promise.all(segments.map(seg => this.fetchSegment(url, seg, handle, totalBytes, state, entry)));
        } finally {
            await handle.close();
        }
        return totalBytes;
    }

    /** One `Range:` segment, written at its absolute offset (disjoint → safe concurrently). */
    private async fetchSegment(
        url: string, seg: DownloadSegment, handle: FileHandle,
        total: number, state: { received: number; lastPct: number }, entry: ModelEntry,
    ): Promise<void> {
        const res = await fetch(url, { headers: { Range: `bytes=${seg.start}-${seg.end}` } });
        if (res.status !== 206 || !res.body) throw new Error(`range request failed: ${res.status}`);
        const reader = res.body.getReader();
        let position = seg.start;
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            if (value && value.length) {
                await handle.write(value, 0, value.length, position);
                position += value.length;
                state.received += value.length;
                const progress = Math.round((state.received / total) * 100);
                if (progress !== state.lastPct) {
                    state.lastPct = progress;
                    this.emit("model_download_progress", { progress, modelId: entry.id });
                }
            }
        }
    }

    public async generateAction(systemPrompt: string, userPrompt: string, options: GenerationOptions, imagePath?: string, signal?: AbortSignal): Promise<string> {
        const release = nativeWorkloads.beginOrdinary(this);
        try { return await this.generateActionWithLease(systemPrompt, userPrompt, options, imagePath, signal); } finally { release(); }
    }
    private async generateActionWithLease(systemPrompt: string, userPrompt: string, options: GenerationOptions, imagePath?: string, signal?: AbortSignal): Promise<string> {
        if (imagePath?.trim()) throw new Error('Agent actions cannot inspect images. Use the Vision workflow for an image question.');
        if (this.isJaisSelected() || this.isPublisherSelected()) throw new Error('This experimental model supports text chat only. Choose another model for agent actions.');
        this.isGeneratingAction = true;
        try {
            const { context } = await this.getModelAndContext();

            if (this.isJaisSelected() || this.isPublisherSelected()) throw new Error('This experimental model supports text chat only. Choose another model for agent actions.');

            // Grammar-constrained decoding: with a schema, invalid output is unsampleable —
            // the drunk-JSON failure mode is removed at the decoder, not patched in a parser.
            const grammar = options.jsonSchema ? await this.grammarForSchema(options.jsonSchema) : null;

            const promptOptions = {
                // Default maxTokens: agent_decision recipe, never above the HW action budget
                // (tiny phones keep a tighter cap). Explicit options.maxTokens always wins.
                maxTokens: options.maxTokens ?? agentDecisionMaxTokensCapped(HW.actionMaxTokens),
                // ?? not ||: an explicit temperature 0 (greedy) must stay 0, not silently become
                // the profile default. Default temperature is agent_decision from sampling-profiles.json
                // (was a hard-coded 0.1 that drifted from the mobile/agent recipes).
                temperature: options.temperature ?? agentDecisionTemperature(),
                // Anti-loop guard from chat profile (1.1/256) — same numbers as Swift/Android.
                // Composes with the grammar mask.
                repeatPenalty: { penalty: REPEAT_PENALTY, lastTokens: REPEAT_LAST_N },
                ...(grammar ? { grammar } : {})
            };

            const runDecode = async (useCachedSequence: boolean): Promise<string> => {
                // cacheKey path: reuse ONE long-lived sequence so the stable prompt prefix
                // (system prompt, goal, attachments, hints) stays in KV cache across calls.
                // A FRESH session is created every call — semantics remain stateless; only
                // the token cache persists. Ephemeral path: sequence disposed with the session.
                let sequence: any;
                let ownsSequence = true;
                if (useCachedSequence && options.cacheKey) {
                    const existing = this.actionSequences.get(options.cacheKey);
                    // Input-lookup (prompt-lookup) speculative decoding on mission sequences:
                    // agent JSON echoes prompt tokens (element ids, action names, typed text), the
                    // classic input-grounded case — several output tokens verified per decode step,
                    // no draft model needed. Mispredictions cost only the wasted verify, correctness
                    // is unaffected (predictions are validated by the real sampler, grammar included).
                    sequence = existing ?? context.getSequence(
                        typeof _llamaBindings?.InputLookupTokenPredictor === 'function'
                            ? { tokenPredictor: new _llamaBindings.InputLookupTokenPredictor() }
                            : undefined
                    );
                    if (!existing) this.actionSequences.set(options.cacheKey, sequence);
                    ownsSequence = false;
                } else {
                    sequence = context.getSequence();
                }
                const session = this.createChatSession({
                    contextSequence: sequence,
                    systemPrompt: systemPrompt || undefined,
                    autoDisposeSequence: ownsSequence
                });
                try {
                    // Q-405: route through promptWithTimeout so a stalled native decode can't hang
                    // the agent FOREVER. On a hang it throws LLM_TIMEOUT, which the agent loop
                    // surfaces as a clean error instead of a wedged mission.
                    const response = await this.promptWithTimeout(
                        session,
                        userPrompt,
                        promptOptions,
                        this.promptTimeoutMs,
                        'Action generation',
                        signal   // Q-537: agent hard-stop — an aborted signal ends the decode within a token
                    );
                    return response.trim();
                } finally {
                    // Owned sequence dies with the session (autoDisposeSequence); a cached one
                    // survives — dispose only the session wrapper to keep its KV state.
                    try { session.dispose(); } catch { /* already disposed */ }
                }
            };

            try {
                return await runDecode(Boolean(options.cacheKey));
            } catch (err: unknown) {
                // Deliberate cancel and genuine hang are real signals — never mask them with a
                // retry. Anything else on the cached-sequence path is treated as cache poisoning
                // (stale KV, disposed handle after a reload race): drop the sequence and run the
                // same prompt once on a fresh one, restoring exact pre-cache behavior.
                const code = errCode(err);
                if (options.cacheKey && code !== 'LLM_CANCELLED' && code !== 'LLM_TIMEOUT') {
                    logger.warn(`[LLM] Cached-sequence decode failed (${err instanceof Error ? err.message : err}); retrying on a fresh sequence.`);
                    this.releaseActionCache(options.cacheKey);
                    return await runDecode(false);
                }
                throw err;
            }
        } finally {
            this.isGeneratingAction = false;
            this.touchActivity();
        }
    }

    public async generalChat(userMsg: string, onToken?: (token: string) => void, opts?: { plainChat?: boolean; thoughtTokens?: number }): Promise<{ text: string; meta: GenerationMeta }> {
        const release = nativeWorkloads.beginOrdinary(this);
        try { return await this.generalChatWithLease(userMsg, onToken, opts); } finally { release(); }
    }
    private async generalChatWithLease(userMsg: string, onToken?: (token: string) => void, opts?: { plainChat?: boolean; thoughtTokens?: number }): Promise<{ text: string; meta: GenerationMeta }> {
        // Claim the busy flag BEFORE loading: the memory-pressure monitor skips unload only
        // while isInferenceBusy(), and setting it after setup left a window where pressure
        // unloaded the model between "context ready" and the first token — generalChat then
        // awaited a disposed context forever (live-caught: two hung CLI processes, 2026-07-04).
        this.isGeneratingChat = true;
        let context: LlamaContext;
        try {
            ({ context } = await this.getModelAndContext());
        } catch (err) {
            this.isGeneratingChat = false;   // a failed load must not wedge the busy flag
            throw err;
        }

        // Native function calling: when the bindings support it, tools are wired into the DECODER
        // (defineChatSessionFunction) — the model cannot emit a malformed call, the call/result
        // loop runs inside one prompt(), and no tool markup ever reaches the text stream. The XML
        // protocol below remains the fallback for older bindings (and stays the mobile twins'
        // wire format, pinned by the tool-format parity vectors).
        const jais = this.isJaisSelected() || this.isPublisherSelected();
        const useNativeFunctions = !jais && !opts?.plainChat &&
            typeof _llamaBindings?.defineChatSessionFunction === 'function';

        const ensureSession = () => {
            // NO periodic amnesia reset. The old code disposed the session every MAX_CHAT_TURNS
            // (≈20) turns — total conversation memory loss the user could feel. node-llama-cpp's
            // built-in contextShift keeps an overflowing session alive with the SYSTEM PROMPT
            // pinned and recent turns retained (live-verified 2026-07-07 on a 512-token context:
            // 14 turns of real overflow, no crash, ~2× turn latency while shifting, the system
            // prompt's facts still recalled at the end). A session is created only when missing;
            // explicit resets (resetChat, preset switch, timeout retry) still dispose it.
            if (!this.generalChatSession) {
                // Free any outgoing session's KV-cache sequence slot before allocating a new one,
                // or the slot leaks and context.getSequence() below eventually throws "No sequences left".
                this.disposeChatSession();
                // plainChat (the CLI): skip the ~465-token tool preamble. On a RAM-pressed
                // machine the context auto-tunes small enough that persona+tools alone
                // overflow it and chat fails before the first token (live-caught 2026-07-04).
                // Native functions ALSO skip it: the library documents the functions to the model
                // through the chat wrapper itself — the XML preamble would only teach the model a
                // format that is no longer parsed (and waste ~465 tokens of a small context). One
                // short directive remains: small models often IMITATE a function call as plain text
                // instead of emitting the wrapper's real call syntax (live-caught on a 1B) — telling
                // them not to measurably improves trigger reliability at a ~20-token cost.
                const fullSystemPrompt = opts?.plainChat || jais
                    ? this.activePreset.systemPrompt
                    : useNativeFunctions
                        ? `${this.activePreset.systemPrompt}\n\nWhen a calculation, conversion, file read, or lookup is needed, call the corresponding provided function. Never write an imitation of a function call as text.`
                        : `${this.activePreset.systemPrompt}\n\n${buildToolPrompt()}`;
                this.generalChatSession = this.createChatSession({
                    contextSequence: context.getSequence(),
                    systemPrompt: fullSystemPrompt
                });
                const parked = this.parkedChatHistory;
                if (parked && parked.modelId === this.loadedModelId && parked.presetId === this.activePreset.id) {
                    this.generalChatSession.setChatHistory(parked.history);
                }
                this.parkedChatHistory = null;
            }
        };

        try {
            ensureSession();
        } catch (err) {
            this.isGeneratingChat = false;   // getSequence() can throw; don't wedge the flag
            throw err;
        }

        logger.log("[Assistant] Starting private conversation...");
        this.tokenBuffer = "";
        // Q-292: fresh cancel handle for this generation. Captured locally so all three prompt calls
        // (main, timeout-retry, tool-follow-up) share the ONE signal a user "stop" aborts.
        this.chatAbort = new AbortController();
        const cancelSignal = this.chatAbort.signal;

        // --- Generation metadata tracking ---
        const startTime = performance.now();
        let firstTokenTime: number | null = null;
        let tokenCount = 0;

        try {
            // Keep local responses fast — scaled by hardware tier.
            // Pi @ 1-2 tok/s: 128 tokens ≈ 1min. Desktop @ 20+ tok/s: 384 tokens ≈ 15s.
            const responseMaxTokens = Math.min(this.activePreset.maxTokens, HW.chatMaxTokens);

            let toolCallCount = 0;
            // Fresh functions map per response: it carries the per-response call-cap counter (Q-639).
            const nativeFunctions = useNativeFunctions
                ? buildNativeChatFunctions(_llamaBindings!.defineChatSessionFunction, (tool) => {
                    toolCallCount++;
                    logger.log(`[Tool] Native function call: ${tool}`);
                })
                : undefined;
            // The native call/result loop runs INSIDE one prompt() — budget the timeout for the same
            // number of decode rounds the XML path was allowed (1 answer + up to N tool rounds).
            const chatTimeoutMs = useNativeFunctions
                ? this.promptTimeoutMs * (1 + maxToolCallsPerResponse())
                : this.promptTimeoutMs;

            // Function-call rounds consume generation tokens INSIDE the same prompt() — without an
            // allowance, the calls eat the user-visible response budget and the final answer arrives
            // truncated or empty (live-caught: a looping 1B ended with "" at maxTokens).
            const functionCallAllowance = useNativeFunctions ? 96 * maxToolCallsPerResponse() : 0;
            const promptOptions = {
                maxTokens: responseMaxTokens + functionCallAllowance + (jais ? 256 : 0),
                temperature: this.activePreset.temperature,
                // Anti-loop guard (Swift-twin parity) + no-think chat: bound reasoning to 0 tokens so
                // hidden <think> can't eat the whole cap and return an empty answer on tight hardware.
                repeatPenalty: { penalty: REPEAT_PENALTY, lastTokens: REPEAT_LAST_N },
                // Default 0 (no-think chat); the agent's opt-in deliberation think-pass passes a >0 budget
                // so the model can actually reason before it commits to a decision (Swift-twin parity).
                budgets: { thoughtTokens: jais ? 256 : opts?.thoughtTokens ?? CHAT_THOUGHT_TOKEN_BUDGET },
                ...(nativeFunctions ? { functions: nativeFunctions } : {}),
                onTextChunk: onToken ? (chunk: string) => {
                    const clean = stripControlTokensWithOptions(chunk, { trim: false });
                    if (!clean) return;

                    if (firstTokenTime === null) firstTokenTime = performance.now();
                    tokenCount++;

                    this.tokenBuffer += clean;
                    onToken(clean);
                } : undefined
            };

            let response: string;
            try {
                response = await this.promptWithTimeout(
                    this.generalChatSession!,
                    userMsg,
                    promptOptions,
                    chatTimeoutMs,
                    'Chat generation',
                    cancelSignal
                );
            } catch (err: unknown) {
                if (errCode(err) === 'LLM_TIMEOUT') {
                    logger.warn('[LLM] Chat session timed out; resetting session and retrying once');
                    this.disposeChatSession();
                    ensureSession();
                    this.tokenBuffer = '';
                    firstTokenTime = null;
                    tokenCount = 0;
                    response = await this.promptWithTimeout(
                        this.generalChatSession!,
                        userMsg,
                        promptOptions,
                        chatTimeoutMs,
                        'Chat generation retry',
                        cancelSignal
                    );
                } else {
                    throw err;
                }
            }

            // ─── Tool Call Processing (XML fallback path only) ──────────────
            // With native functions the library already ran the call/result loop inside prompt()
            // and the response is final text. The XML loop below serves older bindings.
            // Q-638: execute tool calls and re-prompt in a LOOP, not once. The model can CHAIN tools
            // (use tool A's result to decide a call to tool B); the old single round stripped that
            // second call instead of running it. Bounded by MAX_TOOL_ROUNDS so a model that keeps
            // emitting tool calls can't loop forever — after the cap, any remaining markup is stripped.
            const MAX_TOOL_ROUNDS = useNativeFunctions || jais ? 0 : 3;
            let finalResponse = stripControlTokens(response.trim());

            for (let round = 0; round < MAX_TOOL_ROUNDS && hasToolCalls(finalResponse); round++) {
                const calls = parseToolCalls(finalResponse);
                if (calls.length === 0) break;
                const results = await executeToolCalls(calls);
                toolCallCount += results.length;
                const resultContext = formatToolResults(results);

                // Re-prompt with the tool results. Do NOT strip tool calls off the follow-up here — the
                // loop re-checks `hasToolCalls` so a chained call runs next round instead of being lost.
                try {
                    const followUp = await this.promptWithTimeout(
                        this.generalChatSession!,
                        `Here are the tool results:\n${resultContext}\n\nUse them to answer, or call another tool if you still need more information.`,
                        {
                            maxTokens: responseMaxTokens,
                            temperature: this.activePreset.temperature,
                            onTextChunk: onToken ? (chunk) => {
                                const clean = stripControlTokensWithOptions(chunk, { trim: false });
                                if (!clean) return;
                                tokenCount++;
                                if (onToken) onToken(clean);
                            } : undefined
                        },
                        this.promptTimeoutMs,
                        'Tool follow-up generation',
                        cancelSignal
                    );
                    finalResponse = stripControlTokens(followUp.trim());
                } catch {
                    logger.warn('[LLM] Tool follow-up prompt failed, using stripped response');
                    finalResponse = stripToolCalls(finalResponse);
                    break;
                }
            }
            // Hit the round cap (or a non-empty parse) with tool markup still present → strip it so the
            // user never sees raw tool-call JSON as the answer.
            if (hasToolCalls(finalResponse)) finalResponse = stripToolCalls(finalResponse);

            // Without a streaming callback nothing incremented tokenCount, so meta reported
            // "0 tokens @ 0 tok/s" for a real answer (the CLI's non-streamed path, the smoke
            // harness). Measure the actual output instead of reporting a lie. tok/s stays
            // approximate when tool rounds ran — duration spans them — but approximate beats zero.
            if (tokenCount === 0 && finalResponse.length > 0) {
                try { tokenCount = this.modelInstance?.tokenize(finalResponse).length ?? 0; } catch { /* meta stays 0 */ }
            }

            const finalEndTime = performance.now();
            const totalDurationMs = finalEndTime - startTime;
            const meta: GenerationMeta = {
                tokenCount,
                durationMs: Math.round(totalDurationMs),
                tokensPerSecond: totalDurationMs > 0 ? parseFloat((tokenCount / (totalDurationMs / 1000)).toFixed(1)) : 0,
                timeToFirstTokenMs: firstTokenTime !== null ? Math.round(firstTokenTime - startTime) : 0,
                toolCalls: toolCallCount,
            };

            logger.log(`[LLM] Finished streaming. ${meta.tokenCount} tokens @ ${meta.tokensPerSecond} tok/s, TTFT ${meta.timeToFirstTokenMs}ms${toolCallCount > 0 ? ` (${toolCallCount} tool calls)` : ''}`);
            this.isGeneratingChat = false;
            this.tokenBuffer = "";
            this.chatAbort = null;
            this.touchActivity();
            return { text: finalResponse, meta };
        } catch (error) {
            const partial = this.tokenBuffer;   // capture BEFORE the reset below wipes it
            this.isGeneratingChat = false;
            this.tokenBuffer = "";
            this.chatAbort = null;
            this.touchActivity();
            // Q-292: a user "stop" is not a failure. Return what streamed so far (kept in the
            // transcript, same as the native stopGenerating). An aborted prompt leaves the session
            // mid-decode, so drop it like the timeout path does — the next message rebuilds a fresh
            // session (history resets; an acceptable cost for a deliberate stop).
            if (errCode(error) === 'LLM_CANCELLED') {
                this.disposeChatSession();
                const totalDurationMs = performance.now() - startTime;
                const meta: GenerationMeta = {
                    tokenCount,
                    durationMs: Math.round(totalDurationMs),
                    tokensPerSecond: totalDurationMs > 0 ? parseFloat((tokenCount / (totalDurationMs / 1000)).toFixed(1)) : 0,
                    timeToFirstTokenMs: firstTokenTime !== null ? Math.round(firstTokenTime - startTime) : 0,
                };
                logger.log(`[LLM] Chat cancelled by user after ${tokenCount} tokens.`);
                return { text: stripControlTokens(partial.trim()), meta };
            }
            logger.error("Error during general chat generation:", error);
            throw error; // Bubble up original error for OOM detection
        }
    }

    public updateSettings(settings: { contextSize: number, memorySafetyEnabled: boolean }) {
        this.currentSettings = settings;
        // Don't yank the model out from under an active generation — defer reset
        if (this.isInferenceBusy()) {
            logger.warn('[LLM] Settings updated but model reset deferred (generation in progress)');
            return;
        }
        this.unloadModel();
    }
}
