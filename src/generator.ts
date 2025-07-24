import { LlamaModel, LlamaContext, LlamaChatSession } from "node-llama-cpp";
import path from "path";

// Hard-coded path to the local, pinned model. This is key for determinism.
const modelPath = path.join(process.cwd(), "models", "llama-3-instruct-8b.Q4_K_M.gguf");

// Initialize the model once.
const model = new LlamaModel({ modelPath });
const context = new LlamaContext({ model, threads: 4 });
const session = new LlamaChatSession({ context });

// This is the core generation function.
// In a real app, `contextualPrompt` would be built by the Context Engine.
export async function generateCode(userPrompt: string): Promise<string> {
  console.log("Generating code for prompt:", userPrompt);
  console.log("Loading model... (this may take a moment)");

  // A simple system prompt to guide the model's output.
  const systemPrompt = `You are an expert code generator. Given a prompt, generate only the TypeScript code required to fulfill the request. Do not add any conversational text or markdown formatting.`;

  const contextualPrompt = `
    System: ${systemPrompt}
    User: ${userPrompt}
  `;

  try {
    const response = await session.prompt(contextualPrompt, {
        maxTokens: 2048, // Limit output size
        temperature: 0.1 // Low temperature for more deterministic output
    });

    console.log("Generation complete.");
    return response;
  } catch (error) {
    console.error("Error during generation:", error);
    throw error;
  }
}