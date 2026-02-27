import { getLlama, LlamaModel, LlamaContext, LlamaChatSession, Llama3ChatWrapper, LlamaLogLevel } from "node-llama-cpp";
import path from "path";
import os from "os";
import fs from "fs";
import { EventEmitter } from "events";
import { ILlmProvider } from "../types/index.js";
import { MODEL_CATALOG, modelPath, checkMemoryForModel, type ModelEntry } from "../constants.js";
import { stripControlTokens } from "../utils/stripControlTokens.js";
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
    private currentSettings = {
        contextSize: 2048,
        memorySafetyEnabled: true
    };

    public getActiveModelLabel(): string {
        return MODEL_CATALOG.find(m => m.id === this.activeModelId)?.label ?? this.activeModelId;
    }

    constructor() {
        super();
    }

    public isCurrentlyGenerating(): { isGenerating: boolean, buffer: string } {
        return { isGenerating: this.isGeneratingChat, buffer: this.tokenBuffer };
    }

    public async getModelAndContext() {
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
                return;
            }
        }

        try {
            const response = await fetch(url);

            if (!response.ok) {
                throw new Error(`Failed to download: ${response.status} ${response.statusText}`);
            }

            if (!response.body) {
                throw new Error("Readable stream not found in fetch response");
            }

            const totalBytes = Number(response.headers.get('content-length')) || 0;
            let receivedBytes = 0;
            let lastEmittedProgress = -1;
            const fileStream = fs.createWriteStream(dest);

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
            this.isDownloading = false;

        } catch (error) {
            logger.error("Model download pipeline failed:", error);
            fs.unlink(dest, () => { }); // Handle local cleanup
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

    public async generalChat(userMsg: string, onToken?: (token: string) => void): Promise<string> {
        const { context } = await this.getModelAndContext();
        if (!this.generalChatSession) {
            const systemPrompt = `You are Quenderin, a helpful, intelligent, and offline AI assistant running locally on the user's hardware. You are friendly, highly capable, and concise. formatting your responses in beautiful Markdown.`;
            this.generalChatSession = new LlamaChatSession({
                contextSequence: context.getSequence(),
                systemPrompt: systemPrompt
            });
        }

        logger.log("[Assistant] Starting private conversation...");
        this.isGeneratingChat = true;
        this.tokenBuffer = "";
        let flushTimer: NodeJS.Timeout | null = null;

        try {
            const response = await this.generalChatSession.prompt(userMsg, {
                maxTokens: 2048,
                temperature: 0.7,
                onTextChunk: onToken ? (chunk) => {
                    // Strip control tokens from each chunk before buffering
                    const clean = stripControlTokens(chunk);
                    if (!clean) return;
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

            logger.log("\n[LLM] Finished streaming.");
            this.isGeneratingChat = false;
            this.tokenBuffer = "";
            return stripControlTokens(response.trim());
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
