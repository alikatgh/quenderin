import { getLlama, LlamaModel, LlamaContext, LlamaChatSession } from "node-llama-cpp";
import path from "path";
import os from "os";

// Hard-coded path to the local, pinned model. This is key for determinism.
// Pointing to a user directory allows the packaged Electron app to remain read-only.
const modelPath = path.join(os.homedir(), ".quenderin", "models", "llama-3-instruct-8b.Q4_K_M.gguf");

export class LlmService {
    private modelInstance: LlamaModel | null = null;
    private contextInstance: LlamaContext | null = null;

    public async getModelAndContext() {
        if (this.modelInstance && this.contextInstance) {
            return { model: this.modelInstance, context: this.contextInstance };
        }
        const llama = await getLlama();
        this.modelInstance = await llama.loadModel({ modelPath });
        this.contextInstance = await this.modelInstance.createContext();
        return { model: this.modelInstance, context: this.contextInstance };
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
