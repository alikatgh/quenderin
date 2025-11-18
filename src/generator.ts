import { fileURLToPath } from "url";
import { getLlama, Llama, LlamaModel, LlamaContext, LlamaChatSession } from "node-llama-cpp";
import path from "path";
import fs from "fs";

// Lazy-loaded instances
let llama: Llama | null = null;
let model: LlamaModel | null = null;
let context: LlamaContext | null = null;
let session: LlamaChatSession | null = null;

interface GeneratorConfig {
  modelPath?: string;
  maxTokens?: number;
  temperature?: number;
  threads?: number;
}

/**
 * Find available model in the models directory
 */
function findAvailableModel(): string {
  const modelsDir = path.join(process.cwd(), "models");

  // Check if models directory exists
  if (!fs.existsSync(modelsDir)) {
    throw new Error(
      `Models directory not found at: ${modelsDir}\n` +
      `Please create it and download a model. See models/README.md for instructions.`
    );
  }

  // List of preferred models in order
  const preferredModels = [
    "llama-3-instruct-8b.Q4_K_M.gguf",
    "codellama-7b.Q4_K_M.gguf",
    "phi-3-mini.Q4_K_M.gguf"
  ];

  // Try to find a preferred model
  for (const modelName of preferredModels) {
    const modelPath = path.join(modelsDir, modelName);
    if (fs.existsSync(modelPath)) {
      return modelPath;
    }
  }

  // If no preferred model found, use first .gguf file
  const files = fs.readdirSync(modelsDir);
  const ggufFile = files.find(f => f.endsWith('.gguf'));

  if (ggufFile) {
    return path.join(modelsDir, ggufFile);
  }

  throw new Error(
    `No GGUF model files found in: ${modelsDir}\n` +
    `Please download a model. See models/README.md for instructions.`
  );
}

/**
 * Initialize the LLM model (lazy initialization)
 */
async function initializeModel(config: GeneratorConfig = {}): Promise<void> {
  if (session) {
    return; // Already initialized
  }

  const modelPath = config.modelPath || findAvailableModel();
  const threads = config.threads || 4;

  console.log(`Loading model: ${path.basename(modelPath)}`);
  console.log("This may take 10-30 seconds on first load...");

  try {
    // Initialize Llama instance
    llama = await getLlama();

    // Load the model
    model = await llama.loadModel({ modelPath });

    // Create context with the model
    context = await model.createContext({ threads });

    // Create chat session
    session = new LlamaChatSession({ contextSequence: context.getSequence() });

    console.log("Model loaded successfully!");
  } catch (error: any) {
    throw new Error(
      `Failed to load model: ${error.message}\n` +
      `Model path: ${modelPath}\n` +
      `Make sure the model file exists and is a valid GGUF format.`
    );
  }
}

/**
 * Core code generation function
 *
 * @param userPrompt - The natural language description of code to generate
 * @param config - Optional configuration for model parameters
 * @returns Generated code as a string
 */
export async function generateCode(
  userPrompt: string,
  config: GeneratorConfig = {}
): Promise<string> {
  console.log("\n=== Code Generation Started ===");
  console.log(`Prompt: ${userPrompt}`);

  // Initialize model if needed
  await initializeModel(config);

  if (!session) {
    throw new Error("Failed to initialize LLM session");
  }

  // System prompt to guide the model's output
  const systemPrompt = `You are an expert code generator. Given a prompt, generate only the TypeScript code required to fulfill the request. Do not add any conversational text or markdown formatting. Output clean, production-ready code with appropriate comments.`;

  const contextualPrompt = `${systemPrompt}

User request: ${userPrompt}

Generate the code:`;

  try {
    const response = await session.prompt(contextualPrompt, {
      maxTokens: config.maxTokens || 2048,
      temperature: config.temperature || 0.1 // Low temp for determinism
    });

    console.log("=== Generation Complete ===\n");
    return response.trim();
  } catch (error: any) {
    console.error("Error during generation:", error.message);
    throw new Error(`Code generation failed: ${error.message}`);
  }
}

/**
 * Reset the model (useful for testing or switching models)
 */
export async function resetModel(): Promise<void> {
  session = null;
  if (context) {
    await context.dispose();
    context = null;
  }
  if (model) {
    await model.dispose();
    model = null;
  }
  llama = null;
  console.log("Model reset. Will reinitialize on next generation.");
}