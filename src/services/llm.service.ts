import { getLlama, LlamaModel, LlamaContext, LlamaChatSession } from "node-llama-cpp";
import path from "path";
import os from "os";
import fs from "fs";
import https from "https";
import { EventEmitter } from "events";
import { ILlmProvider } from "../types/index.js";

// Hard-coded path to the local, pinned model. This is key for determinism.
// Hard-coded path to the local, pinned model or overridden via generic env variables
const modelPath = process.env.LLM_MODEL_PATH || path.join(os.homedir(), ".quenderin", "models", "llama-3-instruct-8b.Q4_K_M.gguf");

export class LlmService extends EventEmitter implements ILlmProvider {
    private modelInstance: LlamaModel | null = null;
    private contextInstance: LlamaContext | null = null;
    private initPromise: Promise<{ model: LlamaModel, context: LlamaContext }> | null = null;
    private isDownloading: boolean = false;

    constructor() {
        super();
    }

    public async getModelAndContext() {
        if (this.modelInstance && this.contextInstance) {
            return { model: this.modelInstance, context: this.contextInstance };
        }

        // Mutex lock to prevent multiple concurrent requests from crashing memory
        if (this.initPromise) {
            return this.initPromise;
        }

        this.initPromise = (async () => {
            try {
                const llama = await getLlama();
                const model = await llama.loadModel({ modelPath });
                const context = await model.createContext();
                this.modelInstance = model;
                this.contextInstance = context;
                return { model, context };
            } catch (error: any) {
                if (error.message && error.message.includes('ENOENT')) {
                    this.emit('action_required', {
                        code: 'MODEL_MISSING',
                        title: 'AI Model Missing',
                        message: 'Quenderin needs its brain to function. The LLaMA instruction-tuned checkpoint is absent.'
                    });
                } else {
                    console.error("Failed to load LLaMA model:", error);
                }
                this.initPromise = null;
                throw error;
            }
        })();

        return this.initPromise;
    }

    public async downloadDefaultModel(): Promise<void> {
        if (this.isDownloading) return;
        this.isDownloading = true;

        const url = 'https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true';
        const dest = modelPath;
        const dir = path.dirname(dest);

        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }

        return new Promise((resolve, reject) => {
            const downloadFile = (currentUrl: string) => {
                https.get(currentUrl, (response) => {
                    if (response.statusCode && response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                        return downloadFile(response.headers.location);
                    }

                    if (response.statusCode !== 200) {
                        this.isDownloading = false;
                        return reject(new Error(`Failed to download: ${response.statusCode}`));
                    }

                    const totalBytes = parseInt(response.headers['content-length'] || '0', 10);
                    let receivedBytes = 0;
                    const fileStream = fs.createWriteStream(dest);

                    response.on('data', (chunk) => {
                        receivedBytes += chunk.length;
                        if (totalBytes > 0) {
                            const progress = Math.round((receivedBytes / totalBytes) * 100);
                            this.emit('model_download_progress', { progress });
                        }
                    });

                    response.pipe(fileStream);

                    fileStream.on('finish', () => {
                        fileStream.close();
                        this.isDownloading = false;
                        resolve();
                    });

                    fileStream.on('error', (err) => {
                        fs.unlink(dest, () => { }); // Handle local cleanup
                        this.isDownloading = false;
                        reject(err);
                    });
                }).on('error', (err) => {
                    fs.unlink(dest, () => { });
                    this.isDownloading = false;
                    reject(err);
                });
            };

            downloadFile(url);
        });
    }

    public async generateCode(userPrompt: string): Promise<string> {
        const { context } = await this.getModelAndContext();
        const session = new LlamaChatSession({ contextSequence: context.getSequence() });
        console.log("Generating code for prompt:", userPrompt);
        console.log("Loading model... (this may take a moment)");

        const systemPrompt = `You are an expert code generator. Given a prompt, generate only the TypeScript code required to fulfill the request. Do not add any conversational text or markdown formatting.`;

        const contextualPrompt = `
            System: ${systemPrompt}
            User: ${userPrompt}
        `;

        try {
            const response = await session.prompt(contextualPrompt, {
                maxTokens: 2048,
                temperature: 0.1
            });

            console.log("Generation complete.");
            return response;
        } catch (error) {
            console.error("Error during generation:", error);
            throw error;
        }
    }

    public async generateAction(systemPrompt: string, userPrompt: string, options: any, imagePath?: string): Promise<string> {
        const { context } = await this.getModelAndContext();
        // Use a new session to prevent context bounds filling up endlessly
        const session = new LlamaChatSession({ contextSequence: context.getSequence() });

        const prompt = systemPrompt ? `System: ${systemPrompt}\n\nUser: ${userPrompt}` : `User: ${userPrompt}`;

        // If a vision path was provided, notify the LLM this is a multimodal query (pseudo-implementation since node-llama-cpp's exact vision wrapper syntax varies by binding version)
        const finalPrompt = imagePath
            ? `${prompt}\n[IMAGE UPLOADED: ${imagePath}]`
            : prompt;

        const response = await session.prompt(finalPrompt, {
            maxTokens: options.maxTokens || 150,
            temperature: options.temperature || 0.1
        });

        return response.trim();
    }

    public async generalChat(userMsg: string): Promise<string> {
        const { context } = await this.getModelAndContext();
        // Use a new session without strict tool-use sequences
        const session = new LlamaChatSession({ contextSequence: context.getSequence() });

        console.log("Dispatching General Chat to LLM...");

        const systemPrompt = `You are Quenderin, a helpful, intelligent, and offline AI assistant running locally on the user's hardware. You are friendly, highly capable, and concise. formatting your responses in beautiful Markdown.`;

        const contextualPrompt = `
            System: ${systemPrompt}
            User: ${userMsg}
        `;

        try {
            const response = await session.prompt(contextualPrompt, {
                maxTokens: 2048,
                temperature: 0.7 // Higher temperature for chat feeling
            });

            return response.trim();
        } catch (error) {
            console.error("Error during general chat generation:", error);
            throw new Error('Failed to generate chat response.');
        }
    }
}
