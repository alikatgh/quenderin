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
import { ILlmProvider, GenerationMeta } from "../types/index.js";
import { MODEL_CATALOG, modelPath, checkMemoryForModel, type ModelEntry } from "../constants.js";
import { stripControlTokens, stripControlTokensWithOptions } from "../utils/stripControlTokens.js";
import { getPresetById, type Preset } from "./presets.js";
import { buildToolPrompt } from "./tools/registry.js";
import { hasToolCalls, parseToolCalls, stripToolCalls, formatToolResults } from "./tools/toolLoop.js";
import { executeToolCalls } from "./tools/handlers.js";
import { getHardwareProfile } from "../utils/hardware.js";
import { verifyModelIntegrity } from "./modelIntegrity.js";
import logger from "../utils/logger.js";

/** Narrow unknown catch to an Error-like shape with optional `code` */
function errCode(e: unknown): string | undefined {
    return e instanceof Error ? (e as NodeJS.ErrnoException).code : undefined;
}

/** Error carrying a structured `code` plus optional model hints for action_required events. */
interface TaggedError extends NodeJS.ErrnoException {
    fittingModels?: unknown;
}

// ─── Hardware-adaptive profile (detected once at startup) ───────────────────
const HW = getHardwareProfile();

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
 *    smallest downloaded model with `degraded: true` so the caller can load it
 *    with a minimal context instead of blocking the entire app.
 * 3. Return null only when literally no model file exists on disk.
 */
function selectBestModel(memorySafetyEnabled: boolean): { entry: ModelEntry; path: string; degraded: boolean } | null {
    // Prefer responsiveness first (smallest -> largest) to avoid long blocking TTFT on CPU-only hosts.
    const prioritized = [...MODEL_CATALOG].sort((a, b) => a.paramsBillions - b.paramsBillions);
    let smallestDownloaded: { entry: ModelEntry; path: string } | null = null;

    for (const entry of prioritized) {
        const filePath = modelPath(entry.id);
        // Must exist on disk
        if (!fs.existsSync(filePath)) continue;
        // Track the smallest downloaded model as a last-resort fallback
        if (!smallestDownloaded) smallestDownloaded = { entry, path: filePath };
        // If safety is on, check it fits
        if (memorySafetyEnabled) {
            const memCheck = checkMemoryForModel(entry);
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
    memorySafetyEnabled: boolean
): { entry: ModelEntry; path: string; degraded: boolean } | null {
    const pinned = MODEL_CATALOG.find((m) => m.id === activeModelId);
    if (pinned) {
        const filePath = modelPath(pinned.id);
        if (fs.existsSync(filePath)) {
            if (!memorySafetyEnabled) {
                return { entry: pinned, path: filePath, degraded: false };
            }
            const memCheck = checkMemoryForModel(pinned);
            if (memCheck.canLoad) {
                return { entry: pinned, path: filePath, degraded: false };
            }
            return { entry: pinned, path: filePath, degraded: true };
        }
    }
    return selectBestModel(memorySafetyEnabled);
}

export class LlmService extends EventEmitter implements ILlmProvider {
    private modelInstance: LlamaModel | null = null;
    private contextInstance: LlamaContext | null = null;
    private initPromise: Promise<{ model: LlamaModel, context: LlamaContext }> | null = null;
    private isDownloading: boolean = false;
    private generalChatSession: LlamaChatSession | null = null;
    /** The engine handle from getLlama() — retained ONLY so shutdown() can dispose the
     *  Metal/GPU device before exit (see shutdown's doc comment). */
    private llamaEngine: { dispose(): Promise<void> } | null = null;
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

    // ─── Active Model Lifecycle (ported from off-grid-mobile) ───────────────
    private loadedModelId: string | null = null;
    private modelLoadTimestamp: number = 0;
    /** Tracks actual GPU backend used after init (for diagnostics) */
    private gpuBackendUsed: string = 'unknown';
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

    /** Create a LlamaChatSession using the dynamically imported class */
    private createChatSession(opts: { contextSequence: any; systemPrompt?: string }): any {
        if (!_llamaBindings) throw new Error('LLM bindings not available');
        // autoDisposeSequence: disposing the session frees its KV-cache sequence slot. Without it,
        // each session rotation leaks a slot and context.getSequence() eventually throws
        // "No sequences left" — chat then fails permanently until a full model reload.
        return new _llamaBindings.LlamaChatSession({ ...opts, autoDisposeSequence: true });
    }

    /** Dispose the general chat session (freeing its KV-cache sequence slot) and clear it. */
    private disposeChatSession(): void {
        try { this.generalChatSession?.dispose(); } catch { /* already disposed */ }
        this.generalChatSession = null;
    }

    /** Start the conversation over without unloading the model (CLI `/clear`, UI "new chat"). */
    public resetChat(): void {
        this.disposeChatSession();
        this.chatTurnCount = 0;
    }

    constructor() {
        super();
        this.idleTimeoutMs = this.resolveIdleTimeoutMs();
        logger.log(`[Hardware] ${HW.tier} tier detected: ${HW.platform}/${HW.arch}, ${HW.cpuCores} cores, ${HW.totalRamGb.toFixed(1)}GB RAM, GPU=${HW.tryGpuOffload}, nativeAddons=${HW.nativeAddonsLikely}, timeoutX=${HW.timeoutMultiplier}`);
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

            if (usageRatio > HW.memoryBudgetHard && !this.isInferenceBusy()) {
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
        this.activePreset = preset;
        // Reset chat session to pick up the new system prompt
        this.disposeChatSession();
        logger.log(`[LLM] Preset switched to: ${preset.label}`);
    }

    public getActivePresetId(): string {
        return this.activePreset.id;
    }

    private async promptWithTimeout(
        session: LlamaChatSession,
        prompt: string,
        options: {
            maxTokens: number;
            temperature: number;
            onTextChunk?: (chunk: string) => void;
        },
        timeoutMs: number,
        label: string,
        externalSignal?: AbortSignal
    ): Promise<string> {
        const ac = new AbortController();
        const timer = setTimeout(() => ac.abort(), timeoutMs);
        // Q-292: compose an optional external cancel (user "stop chat") with the timeout — either
        // aborts the same native decode. The action path passes no signal, so its behaviour is
        // unchanged. We classify the abort by CAUSE below: an external cancel is a deliberate stop
        // (LLM_CANCELLED, the caller keeps the partial), the timer is a hang (LLM_TIMEOUT, retried).
        const onExternalAbort = () => ac.abort();
        if (externalSignal) {
            if (externalSignal.aborted) ac.abort();   // already cancelled before the decode began
            else externalSignal.addEventListener('abort', onExternalAbort, { once: true });
        }
        try {
            return await session.prompt(prompt, { ...options, signal: ac.signal });
        } catch (err: unknown) {
            // External cancel takes precedence over the timeout classification: the user asked to stop.
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
            clearTimeout(timer);
            if (externalSignal) externalSignal.removeEventListener('abort', onExternalAbort);
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
            if (!this.isInferenceBusy() && !this.initPromise && this.modelInstance) {
                logger.log(`[Lifecycle] Unloading model after ${this.idleTimeoutMs / 60000}min idle to free RAM`);
                this.unloadModel();
            }
        }, this.idleTimeoutMs);
        this.idleTimer.unref(); // Don't block process exit
    }

    /** Explicitly unload model to free RAM */
    public unloadModel(): void {
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
        void Promise.resolve(context?.dispose()).catch(() => { /* already disposed */ });
        void Promise.resolve(model?.dispose()).catch(() => { /* already disposed */ });
        this.chatTurnCount = 0;
        this.initPromise = null;
        this.loadedModelId = null;
        this.activeModelEntry = null;
        this.gpuBackendUsed = 'unknown';
        this.flashAttentionActive = false;
        if (this.idleTimer) {
            clearTimeout(this.idleTimer);
            this.idleTimer = null;
        }
        this.stopMemoryPressureMonitor();
        if (wasLoaded) logger.log('[Lifecycle] Model unloaded');
    }

    /** Fully tear down for a clean process EXIT: session → context → model → the llama
     *  engine itself, all awaited. Without the final engine dispose, ggml-metal's atexit
     *  destructor asserts (`rsets->data count == 0`, llama.cpp #17869) and a successful
     *  CLI run exits 134 — fatal for pipe consumers checking the code. */
    public async shutdown(): Promise<void> {
        const model = this.modelInstance;
        const context = this.contextInstance;
        this.modelInstance = null;
        this.contextInstance = null;
        this.disposeChatSession();
        try { await context?.dispose(); } catch { /* already disposed */ }
        try { await model?.dispose(); } catch { /* already disposed */ }
        try { await this.llamaEngine?.dispose(); } catch { /* already disposed */ }
        this.llamaEngine = null;
        if (this.idleTimer) { clearTimeout(this.idleTimer); this.idleTimer = null; }
        this.stopMemoryPressureMonitor();
    }

    /** Switch to a specific model by ID. Unloads current model if different. */
    public async switchModel(modelId: string): Promise<void> {
        const entry = MODEL_CATALOG.find((m) => m.id === modelId);
        if (!entry) {
            throw new Error(`Unknown model id: ${modelId}`);
        }
        const filePath = modelPath(modelId);
        if (!fs.existsSync(filePath)) {
            const err = new Error('MODEL_MISSING');
            (err as NodeJS.ErrnoException).code = 'MODEL_MISSING';
            throw err;
        }
        if (this.isInferenceBusy()) {
            // Q-283: THROW, don't silently return — a bare return let WS emit `model_switched` and
            // REST return "Model switched." while nothing changed. Both callers already catch
            // switchModel throws (they must — unknown/missing model throw), so this reports failure.
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

    public async getModelAndContext() {
        this.touchActivity();

        if (this.modelInstance && this.contextInstance) {
            return { model: this.modelInstance, context: this.contextInstance };
        }

        // Mutex lock to prevent multiple concurrent requests from crashing memory
        if (this.initPromise) {
            try {
                return await this.waitWithInitTimeout(this.initPromise, 'Model initialization');
            } catch (error: unknown) {
                if (errCode(error) === 'LLM_INIT_TIMEOUT') {
                    logger.warn('[LLM] Detected stale model init lock; clearing and retrying');
                    this.initPromise = null;
                }
                throw error;
            }
        }

        const promise = (async () => {
            // Hoisted so the catch can dispose a partially-built load (model loaded, context failed).
            let model: LlamaModel | undefined;
            let context: LlamaContext | undefined;
            try {
                // Use pinned activeModelId when its file exists; otherwise auto-select
                const selected = selectPinnedOrBestModel(
                    this.activeModelId,
                    this.currentSettings.memorySafetyEnabled
                );

                if (!selected) {
                    // No model file exists on disk at all — ask user to download one
                    const freeRamGb = availableMemBytes() / (1024 ** 3);
                    const totalRamGb = os.totalmem() / (1024 ** 3);
                    const fittingModels = MODEL_CATALOG.filter(m => {
                        const used = totalRamGb - freeRamGb;
                        return (m.ramGb + used) <= totalRamGb * 0.85;
                    });
                    const err = new Error("MODEL_MISSING") as TaggedError;
                    err.code = "MODEL_MISSING";
                    err.fittingModels = fittingModels.length > 0 ? fittingModels : MODEL_CATALOG;
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
                const llamaInitTimeout = Math.round(30_000 * HW.timeoutMultiplier);

                // ─── 1. Initialize llama engine with GPU fallback ────────────
                // Specify gpu explicitly so Metal/CUDA/Vulkan is negotiated
                // properly. If GPU backend hangs (shader compilation on new
                // chips like M4 Pro), fall back to CPU-only.
                let llama: any;
                const gpuMode = HW.tryGpuOffload ? "auto" : false;
                let resolvedGpuBackend = gpuMode === false ? 'cpu' : 'gpu';
                try {
                    llama = await Promise.race([
                        getLlamaFn({ logLevel: LogLevel.disabled, gpu: gpuMode }),
                        new Promise((_, reject) => setTimeout(() => {
                            reject(new Error(`Llama engine init (gpu=${gpuMode}) timed out after ${llamaInitTimeout / 1000}s`));
                        }, llamaInitTimeout))
                    ]) as any;
                    resolvedGpuBackend = gpuMode === false ? 'cpu' : (HW.platform === 'darwin' ? 'metal' : 'gpu');
                } catch (initErr) {
                    if (gpuMode !== false) {
                        logger.warn('[LLM] GPU backend init failed, retrying CPU-only:', initErr instanceof Error ? initErr.message : initErr);
                        llama = await Promise.race([
                            getLlamaFn({ logLevel: LogLevel.disabled, gpu: false }),
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

                // ─── 2. Load model with GPU offload + AbortController ────────
                // AbortController actually cancels native operations (unlike
                // bare Promise.race which only races the JS promise).
                const loadWithGpu = (gpuLayers: "max" | number) => {
                    const ac = new AbortController();
                    const timer = setTimeout(() => ac.abort(), this.modelInitTimeoutMs);
                    return llama.loadModel({
                        modelPath: selected.path,
                        ...(gpuLayers === "max" ? { gpuLayers: "max" as any } : { gpuLayers }),
                        signal: ac.signal,
                    }).finally(() => clearTimeout(timer));
                };

                if (HW.tryGpuOffload) {
                    try {
                        model = await loadWithGpu("max");
                        logger.log('[LLM] Model loaded with GPU offload (max layers)');
                    } catch (gpuErr) {
                        logger.warn('[LLM] GPU offload failed, falling back to CPU-only:', gpuErr instanceof Error ? gpuErr.message : gpuErr);
                        model = await loadWithGpu(0);
                        logger.log('[LLM] Model loaded in CPU-only mode');
                    }
                } else {
                    // Embedded / headless ARM — skip GPU entirely
                    model = await loadWithGpu(0);
                    logger.log('[LLM] Model loaded in CPU-only mode (embedded hardware)');
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
                    const ac = new AbortController();
                    const timer = setTimeout(() => ac.abort(), this.modelInitTimeoutMs);
                    return model.createContext({
                        contextSize: ctxSize,
                        flashAttention: flash,
                        threads,
                        signal: ac.signal,
                    }).finally(() => clearTimeout(timer));
                };

                const requestedCtx = effectiveCtx;
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
                            useFlashAttention = false;
                        } catch {
                            logger.warn(`[LLM] Reduced context failed, trying minimal (${HW.contextFloor})...`);
                            // Attempt 4: hardware floor, no flash attention
                            context = await tryCreateContext(HW.contextFloor, false);
                            useFlashAttention = false;
                        }
                    }
                }
                logger.log(`[LLM] Context ready: ${requestedCtx} tokens, flashAttention=${useFlashAttention ? 'on' : 'off'}, gpu=${resolvedGpuBackend}, tier=${HW.tier}`);
                this.modelInstance = model;
                this.contextInstance = context;
                this.loadedModelId = selected.entry.id;
                this.modelLoadTimestamp = Date.now();
                this.gpuBackendUsed = resolvedGpuBackend;
                this.flashAttentionActive = useFlashAttention;
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
                void Promise.resolve(context?.dispose()).catch(() => { /* already disposed */ });
                void Promise.resolve(model?.dispose()).catch(() => { /* already disposed */ });
                this.initPromise = null;
                throw error;
            }
        })();

        this.initPromise = promise;
        try {
            return await this.waitWithInitTimeout(promise, 'Model initialization');
        } catch (error: unknown) {
            if (errCode(error) === 'LLM_INIT_TIMEOUT') {
                this.initPromise = null;
                this.modelInstance = null;
                this.contextInstance = null;
                this.disposeChatSession();
                this.loadedModelId = null;
            }
            throw error;
        }
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
        if (this.isDownloading) return;
        this.isDownloading = true;

        const entry = MODEL_CATALOG.find(m => m.id === (modelId ?? MODEL_CATALOG[0].id)) ?? MODEL_CATALOG[0];
        const url = entry.url;
        const dest = modelPath(entry.id);
        const dir = path.dirname(dest);
        const metaPath = dest + '.download.json';

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
            const estimatedSizeGb = entry.ramGb; // rough: download size ≈ RAM footprint for GGUF
            const estimatedBytes = estimatedSizeGb * (1024 ** 3);
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

            if (fs.existsSync(dest) && fs.existsSync(metaPath)) {
                try {
                    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf-8'));
                    const partialStats = fs.statSync(dest);
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

            const isResume = response.status === 206;

            // Validate the resume response before trusting the byte accounting (H9):
            //  • 200 (server ignored our Range — common with CDNs/redirects): the write stream
            //    truncates below, so the counter MUST restart from 0, else progress counts from
            //    the stale partial size and can exceed 100%.
            //  • 206 whose Content-Range starts somewhere other than our partial size: appending
            //    would write at the wrong offset and corrupt the GGUF — discard the partial + retry.
            if (receivedBytes > 0 && !isResume) {
                receivedBytes = 0;
            } else if (isResume) {
                const contentRange = response.headers.get('content-range');
                const startMatch = contentRange ? contentRange.match(/bytes\s+(\d+)-/i) : null;
                if (!startMatch || Number(startMatch[1]) !== receivedBytes) {
                    try { fs.unlinkSync(dest); } catch { /* ignore */ }
                    try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
                    throw new Error(`Download resume offset mismatch (server '${contentRange ?? 'none'}' vs local ${receivedBytes}); discarded partial — please retry.`);
                }
            }

            const contentLength = Number(response.headers.get('content-length')) || 0;
            const totalBytes = isResume ? receivedBytes + contentLength : contentLength;

            // Persist download metadata for resume capability
            fs.writeFileSync(metaPath, JSON.stringify({ modelId: entry.id, totalBytes, startedAt: new Date().toISOString() }));

            let lastEmittedProgress = -1;
            const fileStream = fs.createWriteStream(dest, isResume ? { flags: 'a' } : undefined);
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
            // The bytes are on disk but unverified: a TLS-MITM, poisoned mirror, or
            // truncated transfer could have substituted/corrupted them before they reach
            // node-llama-cpp's GGUF parser (which has memory-corruption→RCE CVEs). Check
            // the GGUF magic header and, when the catalog pins one, the full-file SHA-256.
            // On failure delete the file — a tampered/corrupt result must NOT be kept for
            // resume (the resume path would append to a poisoned partial) — then surface it.
            try {
                await verifyModelIntegrity(dest, entry.sha256);
            } catch (verifyError) {
                try { fs.unlinkSync(dest); } catch { /* ignore */ }
                try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
                throw verifyError;
            }

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

    // Tracks how many turns the current generalChatSession has seen.
    // Scale max turns with the actual context the hardware can handle:
    //   256 ctx → 3 turns, 512 → 6, 1024 → 12, 2048 → 20
    private chatTurnCount: number = 0;
    private get MAX_CHAT_TURNS(): number {
        const ctxSize = this.currentSettings.contextSize;
        return Math.max(3, Math.min(25, Math.floor(ctxSize / 100)));
    }

    public async generateAction(systemPrompt: string, userPrompt: string, options: any, imagePath?: string): Promise<string> {
        this.isGeneratingAction = true;
        try {
            const { context } = await this.getModelAndContext();
            // Use a new sequence per call — dispose it when done to free KV cache slots
            const sequence = context.getSequence();
            const session = this.createChatSession({
                contextSequence: sequence,
                systemPrompt: systemPrompt || undefined
            });

            // If a vision path was provided, notify the LLM this is a multimodal query (pseudo-implementation since node-llama-cpp's exact vision wrapper syntax varies by binding version)
            const finalPrompt = imagePath
                ? `${userPrompt}\n[IMAGE UPLOADED: ${imagePath}]`
                : userPrompt;

            try {
                // Q-405: route through promptWithTimeout so a stalled native decode can't hang the
                // agent FOREVER (the chat path already does this). On a hang it throws LLM_TIMEOUT,
                // which the agent loop surfaces as a clean error instead of a wedged mission.
                const response = await this.promptWithTimeout(
                    session,
                    finalPrompt,
                    {
                        maxTokens: options.maxTokens || HW.actionMaxTokens,
                        temperature: options.temperature || 0.1
                    },
                    this.promptTimeoutMs,
                    'Action generation'
                );
                return response.trim();
            } finally {
                try { sequence.dispose(); } catch { /* already disposed */ }
            }
        } finally {
            this.isGeneratingAction = false;
            this.touchActivity();
        }
    }

    public async generalChat(userMsg: string, onToken?: (token: string) => void, opts?: { plainChat?: boolean }): Promise<{ text: string; meta: GenerationMeta }> {
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

        const ensureSession = () => {
            // Reset session when it approaches the context limit to prevent OOM.
            // At ~80 tokens/turn and a 2048-token context the session starts thrashing around turn 20.
            if (!this.generalChatSession || this.chatTurnCount >= this.MAX_CHAT_TURNS) {
                if (this.chatTurnCount >= this.MAX_CHAT_TURNS) {
                    logger.log(`[LLM] Chat session reached ${this.MAX_CHAT_TURNS} turns — resetting to free context window`);
                }
                // Free the outgoing session's KV-cache sequence slot before allocating a new one,
                // or the slot leaks and context.getSequence() below eventually throws "No sequences left".
                this.disposeChatSession();
                // plainChat (the CLI): skip the ~465-token tool preamble. On a RAM-pressed
                // machine the context auto-tunes small enough that persona+tools alone
                // overflow it and chat fails before the first token (live-caught 2026-07-04).
                const fullSystemPrompt = opts?.plainChat
                    ? this.activePreset.systemPrompt
                    : `${this.activePreset.systemPrompt}\n\n${buildToolPrompt()}`;
                this.generalChatSession = this.createChatSession({
                    contextSequence: context.getSequence(),
                    systemPrompt: fullSystemPrompt
                });
                this.chatTurnCount = 0;
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

            const promptOptions = {
                maxTokens: responseMaxTokens,
                temperature: this.activePreset.temperature,
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
                    this.promptTimeoutMs,
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
                        this.promptTimeoutMs,
                        'Chat generation retry',
                        cancelSignal
                    );
                } else {
                    throw err;
                }
            }

            // ─── Tool Call Processing ───────────────────────────────────────
            // If the response contains tool calls, execute them and re-prompt
            let finalResponse = stripControlTokens(response.trim());
            let toolCallsMade = false;

            if (hasToolCalls(finalResponse)) {
                toolCallsMade = true;
                const calls = parseToolCalls(finalResponse);
                if (calls.length > 0) {
                    const results = await executeToolCalls(calls);
                    const resultContext = formatToolResults(results);

                    // Re-prompt with tool results
                    try {
                        const followUp = await this.promptWithTimeout(
                            this.generalChatSession!,
                            `Here are the tool results:\n${resultContext}\n\nPlease provide your final answer incorporating these results.`,
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
                        finalResponse = stripToolCalls(stripControlTokens(followUp.trim()));
                    } catch {
                        logger.warn('[LLM] Tool follow-up prompt failed, using stripped response');
                        finalResponse = stripToolCalls(finalResponse);
                    }
                }
            }

            const finalEndTime = performance.now();
            const totalDurationMs = finalEndTime - startTime;
            const meta: GenerationMeta = {
                tokenCount,
                durationMs: Math.round(totalDurationMs),
                tokensPerSecond: totalDurationMs > 0 ? parseFloat((tokenCount / (totalDurationMs / 1000)).toFixed(1)) : 0,
                timeToFirstTokenMs: firstTokenTime !== null ? Math.round(firstTokenTime - startTime) : 0,
            };

            logger.log(`[LLM] Finished streaming. ${meta.tokenCount} tokens @ ${meta.tokensPerSecond} tok/s, TTFT ${meta.timeToFirstTokenMs}ms${toolCallsMade ? ' (with tool calls)' : ''}`);
            this.chatTurnCount++;
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
