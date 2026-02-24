#!/usr/bin/env node
import { Command } from 'commander';
import { startDashboardServer } from './server.js';
import { LlmService } from './services/llm.service.js';
import { AgentService } from './services/agent.service.js';
import { AdbService } from './services/adb.service.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService } from './services/memory.service.js';
import { DaemonService } from './services/daemon.service.js';
import { VoiceService } from './services/voice.service.js';

const program = new Command();

program
  .name('quenderin-poc')
  .description('An offline autonomous agent control')
  .version('0.0.1');

// Generate code command - auto-setup if needed
program
  .command('agent')
  .description('Run the autonomous Android simulator agent.')
  .argument('<goal>', 'The objective the agent should accomplish')
  .option('-s, --steps <number>', 'Maximum allowed steps', '20')
  .action(async (goal: string, options) => {
    try {
      const adbService = new AdbService();
      const uiParserService = new UiParserService();
      const llmService = new LlmService();
      const metricsService = new MetricsService();
      const ocrService = new OcrService();
      const memoryService = new MemoryService();
      const agentService = new AgentService(llmService, adbService, uiParserService, metricsService, ocrService, memoryService);

      await agentService.runAgentLoop(goal, parseInt(options.steps, 10));
    } catch (e: any) {
      console.error("Agent encountered a fatal error:", e.message);
    }
  });

program
  .command('dashboard')
  .description('Launch the Agent Web UI dashboard.')
  .option('-p, --port <number>', 'Port for the web server', '3000')
  .action(async (options) => {
    try {
      const adbService = new AdbService();
      const uiParserService = new UiParserService();
      const llmService = new LlmService();
      const metricsService = new MetricsService();
      const ocrService = new OcrService();
      const memoryService = new MemoryService();

      const daemonService = new DaemonService(adbService, uiParserService);
      const agentService = new AgentService(llmService, adbService, uiParserService, metricsService, ocrService, memoryService);

      // We pass a dummy key here. A real implementation would load from process.env.PICOVOICE_API_KEY
      const voiceService = new VoiceService('DEMO_KEY');

      // Start background observation
      daemonService.start();

      // Listen for voice commands and pipe them directly into the Agent Loop
      voiceService.on('command', async (transcribedGoal: string) => {
        console.log(`\n🎙️ Voice Command Received: "${transcribedGoal}"`);
        try {
          await agentService.runAgentLoop(transcribedGoal, 20);
        } catch (e: any) {
          console.error("Agent failed during Voice Command execution:", e.message);
        }
      });

      await voiceService.initialize();

      await startDashboardServer(parseInt(options.port, 10));
    } catch (e: any) {
      console.error("Failed to start dashboard server:", e.message);
    }
  });

// Default command - start interactive mode
if (process.argv.length === 2) {
  console.log('\n Quenderin Agent - Autonomous Android API\n');
  console.log('Commands:');
  console.log('  quenderin dashboard       -  Open web UI for agent monitoring');
  console.log('  quenderin agent "<goal>"  - Run agent with a specific goal');
  console.log('  quenderin --help          - Show all commands\n');
  process.exit(0);
}

program.parse(process.argv);