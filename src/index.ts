#!/usr/bin/env node
import { Command } from 'commander';
import { startDashboardServer } from './server.js';
import { LlmService } from './services/llm.service.js';
import { AgentService } from './services/agent.service.js';
import { AgentEventEmitter } from './services/agent.service.js';
import { AndroidProvider } from './services/providers/android.provider.js';
import { DesktopProvider } from './services/providers/desktop.provider.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService } from './services/memory.service.js';

const program = new Command();

program
  .name('quenderin-poc')
  .description('An offline autonomous agent control')
  .version('0.0.1');

// Run a single agent task from the CLI without starting the full dashboard
program
  .command('agent')
  .description('Run the autonomous Android simulator agent.')
  .argument('<goal>', 'The objective the agent should accomplish')
  .option('-s, --steps <number>', 'Maximum allowed steps', '20')
  .action(async (goal: string, options) => {
    try {
      const targetOS = process.env.TARGET_OS || 'android';
      const deviceProvider = targetOS === 'desktop' ? new DesktopProvider() : new AndroidProvider();

      const uiParserService = new UiParserService();
      const llmService = new LlmService();
      const metricsService = new MetricsService();
      const ocrService = new OcrService();
      const memoryService = new MemoryService();
      const agentService = new AgentService(llmService, deviceProvider, uiParserService, metricsService, ocrService, memoryService);

      const emitter = new AgentEventEmitter();
      emitter.on('status', (msg) => console.log(msg));
      emitter.on('error', (msg) => console.error(msg));
      emitter.on('done', () => console.log('\n[Agent] Done.'));

      await agentService.runAgentLoop(goal, emitter, [], parseInt(options.steps, 10));
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      console.error("Agent encountered a fatal error:", message);
    }
  });

program
  .command('dashboard')
  .description('Launch the Agent Web UI dashboard.')
  .option('-p, --port <number>', 'Port for the web server', '3000')
  .option('--no-open', 'Do not auto-open browser window')
  .action(async (options) => {
    try {
      await startDashboardServer(parseInt(options.port, 10), options.open);
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      console.error("Failed to start dashboard server:", message);
    }
  });

// Default command - start interactive mode
if (process.argv.length === 2) {
  console.log('\n Quenderin Agent - Autonomous Android API\n');
  console.log('Commands:');
  console.log('  quenderin dashboard       -  Open the dashboard');
  console.log('  quenderin agent "<goal>"  - Start a new task');
  console.log('  quenderin --help          - Show all commands\n');
  process.exit(0);
}

program.parse(process.argv);