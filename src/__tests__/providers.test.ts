import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  OllamaProvider,
  OpenAIProvider,
  autoDetectProvider,
} from '../providers.js';

// Mock fetch globally
global.fetch = vi.fn();

describe('providers.ts', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('OllamaProvider', () => {
    it('should initialize with default values', () => {
      const provider = new OllamaProvider();

      expect(provider.name).toBe('Ollama');
    });

    it('should initialize with custom values', () => {
      const provider = new OllamaProvider('llama3', 'http://custom:11434/v1');

      expect(provider.name).toBe('Ollama');
    });

    describe('test()', () => {
      it('should return true when model is available', async () => {
        const mockResponse = {
          ok: true,
          json: async () => ({
            models: [{ name: 'codellama:latest' }],
          }),
        };

        vi.mocked(global.fetch).mockResolvedValue(mockResponse as Response);

        const provider = new OllamaProvider('codellama');
        const result = await provider.test();

        expect(result).toBe(true);
        expect(global.fetch).toHaveBeenCalledWith('http://localhost:11434/api/tags');
      });

      it('should return false when model is not available', async () => {
        const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        const mockResponse = {
          ok: true,
          json: async () => ({
            models: [{ name: 'llama3:latest' }],
          }),
        };

        vi.mocked(global.fetch).mockResolvedValue(mockResponse as Response);

        const provider = new OllamaProvider('codellama');
        const result = await provider.test();

        expect(result).toBe(false);
        expect(consoleLogSpy).toHaveBeenCalledWith(
          expect.stringContaining('Model \'codellama\' not found'),
          expect.anything()
        );

        consoleLogSpy.mockRestore();
      });

      it('should return false when fetch fails', async () => {
        vi.mocked(global.fetch).mockRejectedValue(new Error('Network error'));

        const provider = new OllamaProvider();
        const result = await provider.test();

        expect(result).toBe(false);
      });

      it('should return false when response is not ok', async () => {
        const mockResponse = {
          ok: false,
        };

        vi.mocked(global.fetch).mockResolvedValue(mockResponse as Response);

        const provider = new OllamaProvider();
        const result = await provider.test();

        expect(result).toBe(false);
      });
    });
  });

  describe('OpenAIProvider', () => {
    it('should initialize with API key', () => {
      const provider = new OpenAIProvider('test-key');

      expect(provider.name).toBe('OpenAI-Compatible API');
    });

    it('should initialize with custom model and base URL', () => {
      const provider = new OpenAIProvider(
        'test-key',
        'gpt-4o',
        'https://api.custom.com'
      );

      expect(provider.name).toBe('OpenAI-Compatible API');
    });
  });

  describe('autoDetectProvider', () => {
    it('should return OllamaProvider when codellama is available', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
      const mockResponse = {
        ok: true,
        json: async () => ({
          models: [{ name: 'codellama:latest' }],
        }),
      };

      vi.mocked(global.fetch).mockResolvedValue(mockResponse as Response);

      const provider = await autoDetectProvider();

      expect(provider).not.toBeNull();
      expect(provider?.name).toBe('Ollama');
      expect(consoleLogSpy).toHaveBeenCalledWith(
        expect.stringContaining('Found Ollama with codellama')
      );

      consoleLogSpy.mockRestore();
    });

    it('should try alternative models if codellama not available', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      // First call (codellama) - not found
      // Second call (llama3) - found
      vi.mocked(global.fetch)
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ models: [] }),
        } as Response)
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ models: [{ name: 'llama3:latest' }] }),
        } as Response);

      const provider = await autoDetectProvider();

      expect(provider).not.toBeNull();
      expect(provider?.name).toBe('Ollama');
      expect(consoleLogSpy).toHaveBeenCalledWith(
        expect.stringContaining('Found Ollama with llama3')
      );

      consoleLogSpy.mockRestore();
    });

    it('should return null when no Ollama models are available', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      vi.mocked(global.fetch).mockResolvedValue({
        ok: true,
        json: async () => ({ models: [] }),
      } as Response);

      const provider = await autoDetectProvider();

      expect(provider).toBeNull();
      expect(consoleLogSpy).toHaveBeenCalledWith(
        expect.stringContaining('Ollama not found')
      );

      consoleLogSpy.mockRestore();
    });
  });
});
