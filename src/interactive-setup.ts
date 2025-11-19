#!/usr/bin/env node
import readline from 'readline';
import { saveConfig, QuenderinConfig } from './config.js';
import { autoDetectProvider } from './providers.js';
import fs from 'fs';
import path from 'path';

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(prompt: string): Promise<string> {
  return new Promise((resolve) => {
    rl.question(prompt, resolve);
  });
}

export async function interactiveSetup(silent = false) {
  if (!silent) {
    console.log('\n⚡ Welcome to Quenderin!\n');
    console.log('Let\'s get you set up in less than a minute...\n');
  }

  // First, try auto-detection
  if (!silent) console.log('🔍 Checking for installed LLMs...\n');
  const detected = await autoDetectProvider();

  if (detected) {
    if (!silent) {
      console.log('✅ Found Ollama running locally!\n');
      const useOllama = await question('Use Ollama? (Y/n): ');

      if (!useOllama || useOllama.toLowerCase() === 'y' || useOllama.toLowerCase() === 'yes') {
        saveConfig({ provider: 'auto' });
        console.log('\n✅ Setup complete! Ollama is ready to use.\n');
        console.log('Try it now:');
        console.log('  quenderin add "Create a function to validate email addresses"\n');
        rl.close();
        return true;
      }
    } else {
      // Silent mode - just use Ollama
      saveConfig({ provider: 'auto' });
      console.log('✅ Using Ollama\n');
      rl.close();
      return true;
    }
  }

  // Show options
  console.log('Choose your LLM provider:\n');
  console.log('  1) Ollama (free, local, private)');
  console.log('  2) OpenAI (fast, paid, requires API key)');
  console.log('  3) OpenAI-compatible API (OpenRouter, Groq, etc.)');
  console.log('  4) Skip setup for now\n');

  const choice = await question('Enter your choice (1-4): ');

  switch (choice.trim()) {
    case '1':
      await setupOllama();
      rl.close();
      return true;
    case '2':
      await setupOpenAI();
      rl.close();
      return true;
    case '3':
      await setupOpenAICompatible();
      rl.close();
      return true;
    case '4':
      console.log('\nℹ️  You can run setup again anytime with: quenderin setup\n');
      rl.close();
      return false;
    default:
      console.log('\n❌ Invalid choice. Run "quenderin setup" to try again.\n');
      rl.close();
      return false;
  }
}

// Quick one-line setup for auto mode
export async function quickSetup(): Promise<boolean> {
  // Try auto-detect first
  const detected = await autoDetectProvider();
  if (detected) {
    saveConfig({ provider: 'auto' });
    console.log('✅ Auto-detected Ollama!\n');
    return true;
  }

  // Ask for API key in one line
  console.log('⚡ Quick setup - enter your OpenAI API key (or press Enter to run full setup):\n');
  const apiKey = await question('API Key: ');

  if (apiKey && apiKey.trim().length > 0) {
    const config: QuenderinConfig = {
      provider: 'openai' as const,
      apiKey: apiKey.trim(),
      modelName: 'gpt-4o-mini'
    };
    saveConfig(config);
    const configPath = path.join(process.cwd(), 'quenderin.json');
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
    console.log('\n✅ OpenAI configured! Using gpt-4o-mini\n');
    return true;
  }

  // Run full interactive setup
  return await interactiveSetup();
}

async function setupOllama() {
  console.log('\n🚀 Setting up Ollama...\n');
  console.log('Steps:');
  console.log('  1. Install Ollama from https://ollama.ai');
  console.log('  2. Run: ollama pull codellama');
  console.log('  3. That\'s it!\n');

  const installed = await question('Have you completed these steps? (y/n): ');

  if (installed.toLowerCase() === 'y' || installed.toLowerCase() === 'yes') {
    saveConfig({ provider: 'auto' });
    console.log('\n✅ Great! Ollama is configured.\n');
    console.log('Try it now:');
    console.log('  quenderin add "Create a hello world function"\n');
  } else {
    console.log('\nℹ️  Install Ollama and run "quenderin setup" again.\n');
  }
}

async function setupOpenAI() {
  console.log('\n💳 Setting up OpenAI...\n');

  const apiKey = await question('Enter your OpenAI API key: ');

  if (!apiKey || apiKey.trim().length === 0) {
    console.log('\n❌ API key required. Run "quenderin setup" to try again.\n');
    return;
  }

  const model = await question('Model name (default: gpt-4o-mini): ');
  const modelName = model.trim() || 'gpt-4o-mini';

  const config: QuenderinConfig = {
    provider: 'openai' as const,
    apiKey: apiKey.trim(),
    modelName: modelName
  };

  saveConfig(config);

  // Also save to quenderin.json in current directory
  const configPath = path.join(process.cwd(), 'quenderin.json');
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

  console.log('\n✅ OpenAI configured successfully!\n');
  console.log('Config saved to: quenderin.json\n');
  console.log('Try it now:');
  console.log('  quenderin add "Create a function to calculate fibonacci numbers"\n');
}

async function setupOpenAICompatible() {
  console.log('\n🔌 Setting up OpenAI-compatible API...\n');

  const baseURL = await question('Enter your API base URL: ');
  const apiKey = await question('Enter your API key: ');
  const model = await question('Enter model name: ');

  if (!baseURL || !apiKey || !model) {
    console.log('\n❌ All fields are required. Run "quenderin setup" to try again.\n');
    return;
  }

  const config: QuenderinConfig = {
    provider: 'openai' as const,
    baseURL: baseURL.trim(),
    apiKey: apiKey.trim(),
    modelName: model.trim()
  };

  saveConfig(config);

  // Also save to quenderin.json in current directory
  const configPath = path.join(process.cwd(), 'quenderin.json');
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

  console.log('\n✅ API configured successfully!\n');
  console.log('Config saved to: quenderin.json\n');
  console.log('Try it now:');
  console.log('  quenderin add "Create a REST API endpoint"\n');
}
