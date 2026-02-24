import { getLlama, LlamaModel, LlamaContext, LlamaChatSession } from "node-llama-cpp";
import path from "path";
import os from "os";
import { ILlmProvider } from "../types/index.js";

// Hard-coded path to the local, pinned model. This is key for determinism.
// Hard-coded path to the local, pinned model or overridden via generic env variables
const modelPath = process.env.LLM_MODEL_PATH || path.join(os.homedir(), ".quenderin", "models", "llama-3-instruct-8b.Q4_K_M.gguf");

export class LlmService implements ILlmProvider {
    private modelInstance: LlamaModel | null = null;
    private contextInstance: LlamaContext | null = null;
    private initPromise: Promise<{ model: LlamaModel, context: LlamaContext }> | null = null;

    public async getModelAndContext() {
        if (this.modelInstance && this.contextInstance) {
            return { model: this.modelInstance, context: this.contextInstance };
        }

        // Mutex lock to prevent multiple concurrent requests from crashing memory
        if (this.initPromise) {
            return this.initPromise;
        }

        this.initPromise = (async () => {
            const llama = await getLlama();
            const model = await llama.loadModel({ modelPath });
            const context = await model.createContext();
            this.modelInstance = model;
            this.contextInstance = context;
            return { model, context };
        })();

        return this.initPromise;
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
