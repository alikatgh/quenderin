import { describe, it, expect, beforeEach, vi } from 'vitest';
import * as config from '../config.js';
import * as providers from '../providers.js';

vi.mock('../config.js');
vi.mock('../providers.js');

describe('unified-generator.ts', () => {
  let generateCodeSimple: typeof import('../unified-generator.js').generateCodeSimple;
  let testConnection: typeof import('../unified-generator.js').testConnection;

  beforeEach(async () => {
    vi.clearAllMocks();
    // Reset module to clear currentProvider cache
    vi.resetModules();
    const module = await import('../unified-generator.js');
    generateCodeSimple = module.generateCodeSimple;
    testConnection = module.testConnection;
  });

  describe('generateCodeSimple', () => {
    it('should generate code using auto-detected provider', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      const mockProvider = {
        name: 'Ollama',
        generateCode: vi.fn().mockResolvedValue('const foo = "bar";'),
        test: vi.fn().mockResolvedValue(true),
      };

      vi.mocked(config.loadConfig).mockReturnValue({});
      vi.mocked(providers.autoDetectProvider).mockResolvedValue(mockProvider);

      const result = await generateCodeSimple('Create a variable');

      expect(result).toBe('const foo = "bar";');
      expect(mockProvider.generateCode).toHaveBeenCalledWith(
        'Create a variable',
        expect.stringContaining('expert code generator'),
        2048,
        0.1
      );

      consoleLogSpy.mockRestore();
    });

    it('should throw error when no provider is available', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      vi.mocked(config.loadConfig).mockReturnValue({});
      vi.mocked(providers.autoDetectProvider).mockResolvedValue(null);

      await expect(generateCodeSimple('test')).rejects.toThrow(
        'No LLM provider found!'
      );

      consoleLogSpy.mockRestore();
    });

    it('should use OpenAI provider when configured', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      const mockProvider = {
        name: 'OpenAI-Compatible API',
        generateCode: vi.fn().mockResolvedValue('const result = 42;'),
        test: vi.fn().mockResolvedValue(true),
      } as any;

      vi.mocked(config.loadConfig).mockReturnValue({
        provider: 'openai' as const,
        apiKey: 'test-key',
        modelName: 'gpt-4',
      });

      vi.mocked(providers.OpenAIProvider).mockImplementation(() => mockProvider);

      const result = await generateCodeSimple('Create a constant');

      expect(result).toBe('const result = 42;');

      consoleLogSpy.mockRestore();
    });

    it('should throw error when OpenAI provider has no API key', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      vi.mocked(config.loadConfig).mockReturnValue({
        provider: 'openai' as const,
        // No API key
      });

      await expect(generateCodeSimple('test')).rejects.toThrow(
        'OpenAI API key required!'
      );

      consoleLogSpy.mockRestore();
    });

    it('should handle generation errors gracefully', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
      const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

      const mockProvider = {
        name: 'Ollama',
        generateCode: vi.fn().mockRejectedValue(new Error('Network timeout')),
        test: vi.fn().mockResolvedValue(true),
      };

      vi.mocked(config.loadConfig).mockReturnValue({});
      vi.mocked(providers.autoDetectProvider).mockResolvedValue(mockProvider);

      await expect(generateCodeSimple('test')).rejects.toThrow(
        'Code generation failed: Network timeout'
      );

      expect(consoleErrorSpy).toHaveBeenCalledWith(
        'Error during generation:',
        'Network timeout'
      );

      consoleLogSpy.mockRestore();
      consoleErrorSpy.mockRestore();
    });
  });

  describe('testConnection', () => {
    it('should return true when connection succeeds', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      const mockProvider = {
        name: 'Ollama',
        generateCode: vi.fn(),
        test: vi.fn().mockResolvedValue(true),
      };

      vi.mocked(config.loadConfig).mockReturnValue({});
      vi.mocked(providers.autoDetectProvider).mockResolvedValue(mockProvider);

      const result = await testConnection();

      expect(result).toBe(true);
      expect(consoleLogSpy).toHaveBeenCalledWith(
        expect.stringContaining('Successfully connected to Ollama')
      );

      consoleLogSpy.mockRestore();
    });

    it('should return false when connection fails', async () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
      const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

      vi.mocked(config.loadConfig).mockReturnValue({});
      vi.mocked(providers.autoDetectProvider).mockResolvedValue(null);

      const result = await testConnection();

      expect(result).toBe(false);
      expect(consoleErrorSpy).toHaveBeenCalledWith(
        expect.stringContaining('Connection failed')
      );

      consoleLogSpy.mockRestore();
      consoleErrorSpy.mockRestore();
    });
  });
});
