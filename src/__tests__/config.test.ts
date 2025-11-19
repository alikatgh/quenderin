import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import path from 'path';
import { loadConfig, saveConfig, createDefaultConfig } from '../config.js';

// Mock fs module
vi.mock('fs');

describe('config.ts', () => {
  const mockConfigPath = path.join(process.cwd(), 'quenderin.json');

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.resetAllMocks();
  });

  describe('loadConfig', () => {
    it('should return empty object when config file does not exist', () => {
      vi.mocked(fs.existsSync).mockReturnValue(false);

      const result = loadConfig();

      expect(result).toEqual({});
      expect(fs.existsSync).toHaveBeenCalledWith(mockConfigPath);
    });

    it('should load and parse valid config file', () => {
      const mockConfig = {
        provider: 'openai',
        apiKey: 'test-key',
        modelName: 'gpt-4',
      };

      vi.mocked(fs.existsSync).mockReturnValue(true);
      vi.mocked(fs.readFileSync).mockReturnValue(JSON.stringify(mockConfig));

      const result = loadConfig();

      expect(result).toEqual(mockConfig);
      expect(fs.readFileSync).toHaveBeenCalledWith(mockConfigPath, 'utf-8');
    });

    it('should return empty object and warn on invalid JSON', () => {
      const consoleWarnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

      vi.mocked(fs.existsSync).mockReturnValue(true);
      vi.mocked(fs.readFileSync).mockReturnValue('invalid json{');

      const result = loadConfig();

      expect(result).toEqual({});
      expect(consoleWarnSpy).toHaveBeenCalled();

      consoleWarnSpy.mockRestore();
    });
  });

  describe('saveConfig', () => {
    it('should save config to file with proper formatting', () => {
      const mockConfig = {
        provider: 'ollama' as const,
        modelName: 'codellama',
      };

      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      saveConfig(mockConfig);

      expect(fs.writeFileSync).toHaveBeenCalledWith(
        mockConfigPath,
        JSON.stringify(mockConfig, null, 2)
      );
      expect(consoleLogSpy).toHaveBeenCalledWith(
        expect.stringContaining('Configuration saved')
      );

      consoleLogSpy.mockRestore();
    });

    it('should throw error when write fails', () => {
      const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
      const mockError = new Error('Write failed');

      vi.mocked(fs.writeFileSync).mockImplementation(() => {
        throw mockError;
      });

      expect(() => saveConfig({})).toThrow('Write failed');
      expect(consoleErrorSpy).toHaveBeenCalled();

      consoleErrorSpy.mockRestore();
    });
  });

  describe('createDefaultConfig', () => {
    it('should create and save default configuration', () => {
      const consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      const result = createDefaultConfig();

      expect(result).toEqual({
        maxTokens: 2048,
        temperature: 0.1,
        threads: 4,
        outputDir: 'src/gen',
      } as const);

      expect(fs.writeFileSync).toHaveBeenCalled();

      consoleLogSpy.mockRestore();
    });
  });
});
