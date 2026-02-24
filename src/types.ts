/**
 * Type definitions for Quenderin
 */

// Ollama API response types
export interface OllamaModel {
  name: string;
  size?: number;
  digest?: string;
  modified_at?: string;
}

export interface OllamaTagsResponse {
  models: OllamaModel[];
}

// Error types
export class QuenderinError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'QuenderinError';
  }
}

export class ConfigError extends QuenderinError {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export class ProviderError extends QuenderinError {
  constructor(message: string) {
    super(message);
    this.name = 'ProviderError';
  }
}

export class GenerationError extends QuenderinError {
  constructor(message: string) {
    super(message);
    this.name = 'GenerationError';
  }
}
