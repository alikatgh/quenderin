/**
 * Unified code generator that supports multiple backends
 */

import { LLMProvider, OllamaProvider, OpenAIProvider, autoDetectProvider } from './providers.js';
import { loadConfig } from './config.js';
import fs from 'fs';

let currentProvider: LLMProvider | null = null;

export interface SimpleGeneratorConfig {
  provider?: 'ollama' | 'openai' | 'auto';
  apiKey?: string;
  modelName?: string;
  baseURL?: string;
  maxTokens?: number;
  temperature?: number;
}

/**
 * Initialize the LLM provider
 */
async function initializeProvider(config: SimpleGeneratorConfig = {}): Promise<LLMProvider> {
  if (currentProvider) {
    return currentProvider;
  }

  const fileConfig = loadConfig();
  const mergedConfig = { ...fileConfig, ...config };

  // Auto-detect if not specified
  if (!mergedConfig.provider || mergedConfig.provider === 'auto') {
    console.log('🔍 Auto-detecting LLM provider...\n');

    const detected = await autoDetectProvider();
    if (detected) {
      currentProvider = detected;
      return detected;
    }

    throw new Error(
      'No LLM provider found!\n\n' +
      'Options:\n' +
      '1. Install Ollama: https://ollama.ai\n' +
      '   Then run: ollama pull codellama\n\n' +
      '2. Use OpenAI API:\n' +
      '   Create quenderin.json with:\n' +
      '   {"provider": "openai", "apiKey": "sk-...", "modelName": "gpt-4"}\n\n' +
      '3. Download a GGUF model (see models/README.md)\n'
    );
  }

  // Create specified provider
  if (mergedConfig.provider === 'ollama') {
    const provider = new OllamaProvider(
      mergedConfig.modelName || 'codellama',
      mergedConfig.baseURL
    );

    const isAvailable = await provider.test();
    if (!isAvailable) {
      throw new Error(
        `Ollama not available!\n` +
        `Make sure Ollama is running and has the ${mergedConfig.modelName || 'codellama'} model installed.\n\n` +
        `Install: https://ollama.ai\n` +
        `Then run: ollama pull ${mergedConfig.modelName || 'codellama'}`
      );
    }

    currentProvider = provider;
    return provider;
  }

  if (mergedConfig.provider === 'openai') {
    if (!mergedConfig.apiKey) {
      throw new Error(
        'OpenAI API key required!\n' +
        'Add to quenderin.json:\n' +
        '{"provider": "openai", "apiKey": "sk-...", "modelName": "gpt-4"}'
      );
    }

    const provider = new OpenAIProvider(
      mergedConfig.apiKey,
      mergedConfig.modelName || 'gpt-4',
      mergedConfig.baseURL
    );

    currentProvider = provider;
    return provider;
  }

  throw new Error(`Unknown provider: ${mergedConfig.provider}`);
}

/**
 * Generate code using the configured provider
 */
export async function generateCodeSimple(
  userPrompt: string,
  config: SimpleGeneratorConfig = {}
): Promise<string> {
  console.log('\n=== Code Generation Started ===');
  console.log(`Prompt: ${userPrompt}\n`);

  const provider = await initializeProvider(config);
  console.log(`Using provider: ${provider.name}\n`);

  const systemPrompt =
    `You are an expert code generator. Given a prompt, generate only the TypeScript code required to fulfill the request. ` +
    `Do not add any conversational text or markdown formatting. Output clean, production-ready code with appropriate comments.`;

  try {
    const result = await provider.generateCode(
      userPrompt,
      systemPrompt,
      config.maxTokens || 2048,
      config.temperature || 0.1
    );

    console.log('=== Generation Complete ===\n');
    return result.trim();
  } catch (error: any) {
    console.error('Error during generation:', error.message);
    throw new Error(`Code generation failed: ${error.message}`);
  }
}

/**
 * Test connection to LLM provider
 */
export async function testConnection(config: SimpleGeneratorConfig = {}): Promise<boolean> {
  try {
    const provider = await initializeProvider(config);
    console.log(`✓ Successfully connected to ${provider.name}`);
    return true;
  } catch (error: any) {
    console.error(`✗ Connection failed: ${error.message}`);
    return false;
  }
}
