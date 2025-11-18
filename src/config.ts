import fs from 'fs';
import path from 'path';

export interface QuenderinConfig {
  modelPath?: string;
  maxTokens?: number;
  temperature?: number;
  threads?: number;
  outputDir?: string;
}

const CONFIG_FILENAME = 'quenderin.json';

/**
 * Load configuration from quenderin.json if it exists
 */
export function loadConfig(): QuenderinConfig {
  const configPath = path.join(process.cwd(), CONFIG_FILENAME);

  if (!fs.existsSync(configPath)) {
    return {};
  }

  try {
    const configContent = fs.readFileSync(configPath, 'utf-8');
    return JSON.parse(configContent);
  } catch (error: any) {
    console.warn(`Warning: Could not parse ${CONFIG_FILENAME}: ${error.message}`);
    return {};
  }
}

/**
 * Save configuration to quenderin.json
 */
export function saveConfig(config: QuenderinConfig): void {
  const configPath = path.join(process.cwd(), CONFIG_FILENAME);

  try {
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
    console.log(`Configuration saved to ${CONFIG_FILENAME}`);
  } catch (error: any) {
    console.error(`Error saving configuration: ${error.message}`);
    throw error;
  }
}

/**
 * Create default configuration file
 */
export function createDefaultConfig(): QuenderinConfig {
  const defaultConfig: QuenderinConfig = {
    maxTokens: 2048,
    temperature: 0.1,
    threads: 4,
    outputDir: 'src/gen'
  };

  saveConfig(defaultConfig);
  return defaultConfig;
}
