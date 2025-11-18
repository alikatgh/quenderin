/**
 * LLM Provider Abstraction
 * Supports multiple backends: Ollama, OpenAI-compatible APIs, and local GGUF models
 */

import OpenAI from 'openai';

export interface LLMProvider {
  name: string;
  generateCode(prompt: string, systemPrompt: string, maxTokens: number, temperature: number): Promise<string>;
  test(): Promise<boolean>;
}

/**
 * Ollama Provider - Uses local Ollama installation
 * Super simple: just needs Ollama running with a model
 */
export class OllamaProvider implements LLMProvider {
  name = 'Ollama';
  private modelName: string;
  private baseURL: string;

  constructor(modelName: string = 'codellama', baseURL: string = 'http://localhost:11434/v1') {
    this.modelName = modelName;
    this.baseURL = baseURL;
  }

  async test(): Promise<boolean> {
    try {
      const response = await fetch(`${this.baseURL.replace('/v1', '')}/api/tags`);
      if (!response.ok) return false;

      const data: any = await response.json();
      const hasModel = data.models?.some((m: any) => m.name.includes(this.modelName));

      if (!hasModel) {
        console.log(`Model '${this.modelName}' not found. Available models:`,
          data.models?.map((m: any) => m.name).join(', ') || 'none');
      }

      return hasModel;
    } catch (error) {
      return false;
    }
  }

  async generateCode(prompt: string, systemPrompt: string, maxTokens: number, temperature: number): Promise<string> {
    const client = new OpenAI({
      baseURL: this.baseURL,
      apiKey: 'ollama', // Ollama doesn't need a real API key
    });

    const response = await client.chat.completions.create({
      model: this.modelName,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: prompt }
      ],
      max_tokens: maxTokens,
      temperature: temperature,
    });

    return response.choices[0]?.message?.content || '';
  }
}

/**
 * OpenAI-Compatible Provider - Works with OpenAI, OpenRouter, LocalAI, etc.
 */
export class OpenAIProvider implements LLMProvider {
  name = 'OpenAI-Compatible API';
  private client: OpenAI;
  private modelName: string;

  constructor(apiKey: string, modelName: string = 'gpt-4', baseURL?: string) {
    this.client = new OpenAI({
      apiKey,
      baseURL,
    });
    this.modelName = modelName;
  }

  async test(): Promise<boolean> {
    try {
      await this.client.models.list();
      return true;
    } catch (error) {
      return false;
    }
  }

  async generateCode(prompt: string, systemPrompt: string, maxTokens: number, temperature: number): Promise<string> {
    const response = await this.client.chat.completions.create({
      model: this.modelName,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: prompt }
      ],
      max_tokens: maxTokens,
      temperature: temperature,
    });

    return response.choices[0]?.message?.content || '';
  }
}

/**
 * Auto-detect and create the best available provider
 */
export async function autoDetectProvider(): Promise<LLMProvider | null> {
  // Try Ollama first (easiest if installed)
  console.log('🔍 Checking for Ollama...');
  const ollama = new OllamaProvider('codellama');
  if (await ollama.test()) {
    console.log('✓ Found Ollama with codellama model');
    return ollama;
  }

  // Try with other common Ollama models
  const ollamaModels = ['llama3', 'llama2', 'mistral', 'phi3'];
  for (const model of ollamaModels) {
    const provider = new OllamaProvider(model);
    if (await provider.test()) {
      console.log(`✓ Found Ollama with ${model} model`);
      return provider;
    }
  }

  console.log('✗ Ollama not found or no models installed');
  return null;
}
