import { Command } from 'commander';
import { startDashboardServer } from './server.js';
import { LlmService } from './services/llm.service.js';
import { AgentService } from './services/agent.service.js';
import { AdbService } from './services/adb.service.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService } from './services/memory.service.js';

const program = new Command();

program
  .name('quenderin-poc')
  .description('An offline autonomous agent control')
  .version('0.0.1');

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
      await startDashboardServer(parseInt(options.port, 10));
    } catch (e: any) {
      console.error("Failed to start dashboard server:", e.message);
    }
  });

program
  .command('add')
  .description('Generate code from a natural language prompt.')
  .argument('<prompt>', 'The feature to generate in plain english')
  .action(async (prompt: string) => {
    try {
      const llmService = new LlmService();
      const generatedCode = await llmService.generateCode(prompt);
      console.log("\n--- Generated Code ---\n");
      console.log(generatedCode);
      console.log("\n----------------------\n");
    } catch (e) {
      console.error("Failed to generate code.");
    }
  });

program.parse(process.argv);