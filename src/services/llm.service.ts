import { getLlama, LlamaModel, LlamaContext, LlamaChatSession, Llama3ChatWrapper, LlamaLogLevel } from "node-llama-cpp";
import path from "path";
import os from "os";
import fs from "fs";
import { EventEmitter } from "events";
import { ILlmProvider, GenerationMeta } from "../types/index.js";
import { MODEL_CATALOG, modelPath, checkMemoryForModel, type ModelEntry } from "../constants.js";
import { stripControlTokens } from "../utils/stripControlTokens.js";
import { getPresetById, type Preset } from "./presets.js";
import { buildToolPrompt } from "./tools/registry.js";
import { hasToolCalls, parseToolCalls, stripToolCalls, formatToolResults } from "./tools/toolLoop.js";
import { executeToolCalls } from "./tools/handlers.js";
import logger from "../utils/logger.js";

/** Pick the best catalog model whose RAM footprint fits within safe limits */
function selectBestModel(memorySafetyEnabled: boolean): { entry: ModelEntry; path: string } | null {
    for (const entry of MODEL_CATALOG) {
        const filePath = modelPath(entry.id);
        // Must exist on disk
        if (!fs.existsSync(filePath)) continue;
        // If safety is on, check it fits
        if (memorySafetyEnabled) {
            const memCheck = checkMemoryForModel(entry);
            if (!memCheck.canLoad) continue;
        }
        return { entry, path: filePath };
    }
    return null;
}

export class LlmService extends EventEmitter implements ILlmProvider {
    private modelInstance: LlamaModel | null = null;
    private contextInstance: LlamaContext | null = null;
    private initPromise: Promise<{ model: LlamaModel, context: LlamaContext }> | null = null;
    private isDownloading: boolean = false;
    private generalChatSession: LlamaChatSession | null = null;
    private isGeneratingChat: boolean = false;
    private tokenBuffer: string = "";
    private activeModelId: string = MODEL_CATALOG[0].id;
    private activePreset: Preset = getPresetById('general');
    private currentSettings = {
        contextSize: 2048,
        memorySafetyEnabled: true
    };

    // ─── Active Model Lifecycle (ported from off-grid-mobile) ───────────────
    private loadedModelId: string | null = null;
    private modelLoadTimestamp: number = 0;
    /** Idle timeout — unload model after 30 minutes of inactivity to free RAM */
    private idleTimeoutMs: number = 30 * 60 * 1000;
    private idleTimer: NodeJS.Timeout | null = null;
    private lastActivityTimestamp: number = 0;

    public getActiveModelLabel(): string {
        return MODEL_CATALOG.find(m => m.id === this.activeModelId)?.label ?? this.activeModelId;
    }

    constructor() {
        super();
    }

    public isCurrentlyGenerating(): { isGenerating: boolean, buffer: string } {
        return { isGenerating: this.isGeneratingChat, buffer: this.tokenBuffer };
    }

    /** Switch the active preset (persona). Resets chat session so the new system prompt takes effect. */
    public setPreset(presetId: string): void {
        const preset = getPresetById(presetId);
        if (preset.id === this.activePreset.id) return;
        this.activePreset = preset;
        // Reset chat session to pick up the new system prompt
        this.generalChatSession = null;
        logger.log(`[LLM] Preset switched to: ${preset.label}`);
    }

    public getActivePresetId(): string {
        return this.activePreset.id;
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
            if (!this.isGeneratingChat && this.modelInstance) {
                logger.log(`[Lifecycle] Unloading model after ${this.idleTimeoutMs / 60000}min idle to free RAM`);
                this.unloadModel();
            }
        }, this.idleTimeoutMs);
        this.idleTimer.unref(); // Don't block process exit
    }

    /** Explicitly unload model to free RAM */
    public unloadModel(): void {
        this.modelInstance = null;
        this.contextInstance = null;
        this.generalChatSession = null;
        this.initPromise = null;
        this.loadedModelId = null;
        if (this.idleTimer) {
            clearTimeout(this.idleTimer);
            this.idleTimer = null;
        }
        logger.log('[Lifecycle] Model unloaded');
    }

    /** Switch to a specific model by ID. Unloads current model if different. */
    public async switchModel(modelId: string): Promise<void> {
        if (this.isGeneratingChat) {
            logger.warn('[Lifecycle] Cannot switch model during active generation');
            return;
        }
        if (this.loadedModelId === modelId) {
            logger.log(`[Lifecycle] Model ${modelId} already loaded, skipping`);
            return;
        }
        this.unloadModel();
        this.activeModelId = modelId;
        // Pre-warm the model
        await this.getModelAndContext();
    }

    public getModelLifecycleInfo(): { loadedModelId: string | null; loadedSinceMs: number; isGenerating: boolean } {
        return {
            loadedModelId: this.loadedModelId,
            loadedSinceMs: this.modelLoadTimestamp > 0 ? Date.now() - this.modelLoadTimestamp : 0,
            isGenerating: this.isGeneratingChat,
        };
    }

    public async getModelAndContext() {
        this.touchActivity();

        if (this.modelInstance && this.contextInstance) {
            return { model: this.modelInstance, context: this.contextInstance };
        }

        // Mutex lock to prevent multiple concurrent requests from crashing memory
        if (this.initPromise) {
            return this.initPromise;
        }

        const promise = (async () => {
            try {
                // Auto-select the best model that fits available RAM
                const selected = selectBestModel(this.currentSettings.memorySafetyEnabled);

                if (!selected) {
                    // No downloaded model fits — check if any model exists at all
                    const anyExists = MODEL_CATALOG.some(m => fs.existsSync(modelPath(m.id)));
                    const freeRamGb = os.freemem() / (1024 ** 3);
                    const totalRamGb = os.totalmem() / (1024 ** 3);

                    if (!anyExists) {
                        // Tell UI to show download options
                        const fittingModels = MODEL_CATALOG.filter(m => {
                            const used = totalRamGb - freeRamGb;
                            return (m.ramGb + used) <= totalRamGb * 0.85;
                        });
                        const err = new Error("MODEL_MISSING");
                        (err as any).code = "MODEL_MISSING";
                        (err as any).fittingModels = fittingModels;
                        throw err;
                    } else {
                        // Models exist but none fit RAM — tell UI about options
                        const downloadedModels = MODEL_CATALOG.filter(m => fs.existsSync(modelPath(m.id)));
                        const err = new Error("Loading model would exceed safe memory limits");
                        (err as any).code = "OOM_PREVENTION";
                        (err as any).downloadedModels = downloadedModels;
                        (err as any).freeRamGb = freeRamGb.toFixed(1);
                        (err as any).totalRamGb = totalRamGb.toFixed(1);
                        throw err;
                    }
                }

                this.activeModelId = selected.entry.id;
                logger.log(`[LLM] Loading ${selected.entry.label} (~${selected.entry.ramGb}GB RAM)`);

                const freeRamGb = os.freemem() / (1024 ** 3);
                if (freeRamGb < 1.0) {
                    logger.warn(`[System] Warning: Only ${freeRamGb.toFixed(1)}GB RAM free. System may be slow.`);
                }

                // --- GPU / Context Fallback Chain (ported from off-grid-mobile) ---
                // Attempt 1: Default (Metal/CUDA) + requested context
                // Attempt 2: CPU-only + requested context
                // Attempt 3: CPU-only + minimal context (2048)
                const llama = await Promise.race([
                    getLlama({ logLevel: LlamaLogLevel.disabled }),
                    new Promise((_, reject) => setTimeout(() => reject(new Error("Assistant initiation timed out after 30s")), 30000))
                ]) as any;

                const model = await llama.loadModel({ modelPath: selected.path });

                let context: LlamaContext;
                const requestedCtx = this.currentSettings.contextSize;
                try {
                    // Attempt 1: full context (GPU auto-detected by node-llama-cpp)
                    context = await model.createContext({
                        contextSize: requestedCtx
                    });
                } catch (gpuError) {
                    logger.warn('[LLM] Primary context creation failed, trying reduced context (2048)...');
                    try {
                        // Attempt 2: reduced context
                        context = await model.createContext({
                            contextSize: Math.min(requestedCtx, 2048)
                        });
                    } catch (cpuError) {
                        logger.warn('[LLM] Reduced context failed, trying minimal context (512)...');
                        // Attempt 3: minimal context
                        context = await model.createContext({
                            contextSize: 512
                        });
                    }
                }
                this.modelInstance = model;
                this.contextInstance = context;
                this.loadedModelId = selected.entry.id;
                this.modelLoadTimestamp = Date.now();
                return { model, context };
            } catch (error: any) {
                const isModelMissing = error?.code === "MODEL_MISSING" || error?.code === "ENOENT";
                const isOomPrevention = error?.code === "OOM_PREVENTION";

                if (isModelMissing) {
                    this.emit('action_required', {
                        code: 'MODEL_MISSING',
                        title: 'No AI Model Installed',
                        message: 'Download one of the models below to get started. Smaller models use less RAM.',
                        autoTrigger: 'downloadModel',
                        fittingModels: (error as any).fittingModels ?? MODEL_CATALOG
                    });
                } else if (isOomPrevention) {
                    const downloaded = (error as any).downloadedModels ?? [];
                    const free = (error as any).freeRamGb ?? '?';
                    const total = (error as any).totalRamGb ?? '?';
                    this.emit('action_required', {
                        code: 'OOM_PREVENTION',
                        title: 'Not Enough Free RAM',
                        message: `You have ${free}GB free of ${total}GB total. None of your downloaded models fit safely. Try a smaller model or close some apps.`,
                        autoTrigger: null,
                        downloadedModels: downloaded,
                        allModels: MODEL_CATALOG
                    });
                } else {
                    console.error("Failed to load LLaMA model:", error);
                }

                this.initPromise = null;
                throw error;
            }
        })();

        this.initPromise = promise;
        return promise;
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

        // Check if already downloaded
        if (fs.existsSync(dest)) {
            const stats = await fs.promises.stat(dest);
            if (stats.size > 100_000_000) { // 100MB sanity check
                this.emit('model_download_progress', { progress: 100, modelId: entry.id });
                this.isDownloading = false;
                // Clean up stale metadata
                if (fs.existsSync(metaPath)) fs.unlinkSync(metaPath);
                return;
            }
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

            const response = await fetch(url, { headers });

            if (!response.ok && response.status !== 206) {
                throw new Error(`Failed to download: ${response.status} ${response.statusText}`);
            }

            if (!response.body) {
                throw new Error("Readable stream not found in fetch response");
            }

            const isResume = response.status === 206;
            const contentLength = Number(response.headers.get('content-length')) || 0;
            const totalBytes = isResume ? receivedBytes + contentLength : contentLength;

            // Persist download metadata for resume capability
            fs.writeFileSync(metaPath, JSON.stringify({ modelId: entry.id, totalBytes, startedAt: new Date().toISOString() }));

            let lastEmittedProgress = -1;
            const fileStream = fs.createWriteStream(dest, isResume ? { flags: 'a' } : undefined);

            const reader = response.body.getReader();

            while (true) {
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
                    await new Promise<void>(resolve => fileStream.once('drain', resolve));
                }
            }

            await new Promise<void>(resolve => fileStream.end(resolve));

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

    public async generateCode(userPrompt: string): Promise<string> {
        const { context } = await this.getModelAndContext();
        const systemPrompt = `You are an expert code generator. Given a prompt, generate only the TypeScript code required to fulfill the request. Do not add any conversational text or markdown formatting.`;

        const session = new LlamaChatSession({
            contextSequence: context.getSequence(),
            systemPrompt: systemPrompt
        });

        logger.log("[Assistant] Warming up...");

        try {
            const response = await session.prompt(userPrompt, {
                maxTokens: 2048,
                temperature: 0.1
            });

            logger.log("[Assistant] Finished.");
            return stripControlTokens(response);
        } catch (error) {
            logger.error("Error during generation:", error);
            throw error;
        }
    }

    public async generateAction(systemPrompt: string, userPrompt: string, options: any, imagePath?: string): Promise<string> {
        const { context } = await this.getModelAndContext();
        // Use a new session to prevent context bounds filling up endlessly
        const session = new LlamaChatSession({
            contextSequence: context.getSequence(),
            systemPrompt: systemPrompt || undefined
        });

        // If a vision path was provided, notify the LLM this is a multimodal query (pseudo-implementation since node-llama-cpp's exact vision wrapper syntax varies by binding version)
        const finalPrompt = imagePath
            ? `${userPrompt}\n[IMAGE UPLOADED: ${imagePath}]`
            : userPrompt;

        const response = await session.prompt(finalPrompt, {
            maxTokens: options.maxTokens || 150,
            temperature: options.temperature || 0.1
        });

        return response.trim();
    }

    public async generalChat(userMsg: string, onToken?: (token: string) => void): Promise<{ text: string; meta: GenerationMeta }> {
        const { context } = await this.getModelAndContext();
        if (!this.generalChatSession) {
            const toolPrompt = buildToolPrompt();
            const fullSystemPrompt = `${this.activePreset.systemPrompt}\n\n${toolPrompt}`;
            this.generalChatSession = new LlamaChatSession({
                contextSequence: context.getSequence(),
                systemPrompt: fullSystemPrompt
            });
        }

        logger.log("[Assistant] Starting private conversation...");
        this.isGeneratingChat = true;
        this.tokenBuffer = "";
        let flushTimer: NodeJS.Timeout | null = null;

        // --- Generation metadata tracking ---
        const startTime = performance.now();
        let firstTokenTime: number | null = null;
        let tokenCount = 0;

        try {
            const response = await this.generalChatSession.prompt(userMsg, {
                maxTokens: this.activePreset.maxTokens,
                temperature: this.activePreset.temperature,
                onTextChunk: onToken ? (chunk) => {
                    // Strip control tokens from each chunk before buffering
                    const clean = stripControlTokens(chunk);
                    if (!clean) return;

                    // Track first token arrival
                    if (firstTokenTime === null) firstTokenTime = performance.now();
                    tokenCount++;

                    this.tokenBuffer += clean;
                    if (!flushTimer) {
                        flushTimer = setTimeout(() => {
                            onToken(this.tokenBuffer);
                            this.tokenBuffer = "";
                            flushTimer = null;
                        }, 50);
                    }
                } : undefined
            });

            if (flushTimer) {
                clearTimeout(flushTimer);
                if (this.tokenBuffer && onToken) {
                    onToken(this.tokenBuffer);
                }
            }

            const endTime = performance.now();
            const durationMs = endTime - startTime;

            // ─── Tool Call Processing ───────────────────────────────────────
            // If the response contains tool calls, execute them and re-prompt
            let finalResponse = stripControlTokens(response.trim());
            let toolCallsMade = false;

            if (hasToolCalls(finalResponse)) {
                toolCallsMade = true;
                const calls = parseToolCalls(finalResponse);
                if (calls.length > 0) {
                    const results = executeToolCalls(calls);
                    const resultContext = formatToolResults(results);

                    // Re-prompt with tool results
                    try {
                        const followUp = await this.generalChatSession!.prompt(
                            `Here are the tool results:\n${resultContext}\n\nPlease provide your final answer incorporating these results.`,
                            {
                                maxTokens: this.activePreset.maxTokens,
                                temperature: this.activePreset.temperature,
                                onTextChunk: onToken ? (chunk) => {
                                    const clean = stripControlTokens(chunk);
                                    if (!clean) return;
                                    tokenCount++;
                                    if (onToken) onToken(clean);
                                } : undefined
                            }
                        );
                        finalResponse = stripToolCalls(stripControlTokens(followUp.trim()));
                    } catch (err) {
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
            this.isGeneratingChat = false;
            this.tokenBuffer = "";
            return { text: finalResponse, meta };
        } catch (error) {
            this.isGeneratingChat = false;
            this.tokenBuffer = "";
            logger.error("Error during general chat generation:", error);
            throw error; // Bubble up original error for OOM detection
        }
    }

    public updateSettings(settings: { contextSize: number, memorySafetyEnabled: boolean }) {
        this.currentSettings = settings;
        // Don't yank the model out from under an active generation — defer reset
        if (this.isGeneratingChat) {
            logger.warn('[LLM] Settings updated but model reset deferred (generation in progress)');
            return;
        }
        this.modelInstance = null;
        this.contextInstance = null;
        this.generalChatSession = null;
        this.initPromise = null;
    }
}
