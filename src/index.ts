#!/usr/bin/env node
import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import readline from 'readline';
import { MODEL_CATALOG, MODELS_DIR } from './constants.js';
import { setLogLevel } from './utils/logger.js';
import { startDashboardServer } from './server.js';
import { LlmService } from './services/llm.service.js';
import { AgentService } from './services/agent.service.js';
import { AgentEventEmitter } from './services/agent.service.js';
import { AndroidProvider } from './services/providers/android.provider.js';
import { DesktopProvider } from './services/providers/desktop.provider.js';
import { UiParserService } from './services/uiParser.service.js';
import { MetricsService } from './services/metrics.service.js';
import { OcrService } from './services/ocr.service.js';
import { MemoryService, setSharedMemoryService } from './services/memory.service.js';

const program = new Command();

program
  .name('quenderin-poc')
  .description('An offline autonomous agent control')
  // Keep in sync with package.json (was stale at 0.0.1 while package.json read 0.1.0 — Q-046).
  .version('0.1.0');

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
      setSharedMemoryService(memoryService);
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
      const port = parseInt(options.port, 10);
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        console.error(`Invalid --port "${options.port}": must be an integer 1-65535.`);
        process.exitCode = 1;
        return;
      }
      await startDashboardServer(port, options.open);
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      console.error("Failed to start dashboard server:", message);
    }
  });

// ─── The programmer's front door: quenderin chat ───────────────────────────
// Claude Code-inspired ergonomics on a fully local model: an interactive REPL
// with slash commands, and a -p print mode that behaves in pipes
// (`git diff | quenderin chat -p "review this"`). Same model store as the
// desktop app (~/.quenderin/models) — download once, use everywhere.

const dim = (s: string) => `\x1b[2m${s}\x1b[0m`;
const bold = (s: string) => `\x1b[1m${s}\x1b[0m`;

function installedModelIds(): Set<string> {
  return new Set(MODEL_CATALOG.filter(m => fs.existsSync(path.join(MODELS_DIR, m.filename))).map(m => m.id));
}

function printModelTable(activeId?: string): void {
  const installed = installedModelIds();
  console.log('');
  for (const m of MODEL_CATALOG) {
    const mark = m.id === activeId ? '●' : installed.has(m.id) ? '✓' : ' ';
    const state = m.id === activeId ? 'active' : installed.has(m.id) ? 'installed' : m.sizeLabel;
    console.log(`  ${mark} ${m.id.padEnd(16)} ${m.label.padEnd(38)} ${dim(state)}`);
  }
  console.log(dim(`\n  models live in ${MODELS_DIR}\n`));
}

async function readAllStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8').trim();
}

program
  .command('models')
  .description('List the model catalog: what is installed, active, and downloadable.')
  .action(() => printModelTable());

program
  .command('download')
  .description('Download a model by id (see `quenderin models`). SHA-256 verified.')
  .argument('<id>', 'catalog model id, e.g. gemma4-12b')
  .action(async (id: string) => {
    if (!MODEL_CATALOG.some(m => m.id === id)) {
      console.error(`Unknown model "${id}". Run \`quenderin models\` for the list.`);
      process.exitCode = 1;
      return;
    }
    const llm = new LlmService();
    llm.on('model_download_progress', (p: { progress: number }) => {
      process.stdout.write(`\r  downloading ${id} · ${String(p.progress).padStart(3)}%`);
    });
    try {
      await llm.downloadModel(id);
      console.log(`\n  ✓ ${id} installed`);
    } catch (e: unknown) {
      console.error(`\nDownload failed: ${e instanceof Error ? e.message : String(e)}`);
      process.exitCode = 1;
    }
  });

program
  .command('chat')
  .description('Chat with a local model in your terminal — streaming, private, offline.')
  .option('-m, --model <id>', 'model id to use (see `quenderin models`)')
  .option('-p, --print [prompt]', 'answer once and exit; reads stdin when piped (combine both: stdin becomes context)')
  .action(async (options: { model?: string; print?: string | boolean }) => {
    // Silence BEFORE the service exists: engine logs write to STDOUT, and the hardware
    // probe fires in the constructor — one line too early and piped output is polluted.
    if (options.print !== undefined) setLogLevel('error');
    const llm = new LlmService();
    try {
      if (options.model) {
        if (!MODEL_CATALOG.some(m => m.id === options.model)) {
          console.error(`Unknown model "${options.model}". Run \`quenderin models\` for the list.`);
          process.exitCode = 1;
          return;
        }
        await llm.switchModel(options.model);
      }

      // ── -p print mode: one answer, plain stdout, exit. The pipe-friendly path.
      if (options.print !== undefined) {
        const piped = !process.stdin.isTTY ? await readAllStdin() : '';
        const arg = typeof options.print === 'string' ? options.print : '';
        const prompt = [arg, piped].filter(Boolean).join('\n\n');
        if (!prompt) {
          console.error('Nothing to answer: pass a prompt (`-p "…"`) or pipe input.');
          process.exitCode = 1;
          return;
        }
        await llm.generalChat(prompt, tok => process.stdout.write(tok), { plainChat: true });
        process.stdout.write('\n');
        // Full engine dispose before exit — ggml-metal's atexit destructor asserts if the
        // device is still alive (llama.cpp #17869), turning a good run into exit 134.
        await llm.shutdown();
        process.exit(0);
      }

      // ── Interactive REPL.
      console.log(`\n${bold('Quenderin')} ${dim('— on-device · private · nothing leaves this machine')}`);
      console.log(dim(`model: ${llm.getActiveModelLabel()} · /help for commands\n`));

      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      const ask = (): void => {
        rl.question('› ', async (line: string) => {
          const input = line.trim();
          if (!input) return ask();

          if (input === '/exit' || input === '/quit') { rl.close(); await llm.shutdown(); process.exit(0); }
          if (input === '/help') {
            console.log(dim('  /model <id>   switch model      /models   list models'));
            console.log(dim('  /clear        new conversation  /exit     leave\n'));
            return ask();
          }
          if (input === '/models') { printModelTable(); return ask(); }
          if (input === '/clear') { llm.resetChat(); console.log(dim('  conversation cleared\n')); return ask(); }
          if (input.startsWith('/model ')) {
            const id = input.slice(7).trim();
            if (!MODEL_CATALOG.some(m => m.id === id)) {
              console.log(dim(`  unknown model "${id}" — /models for the list\n`));
              return ask();
            }
            try {
              await llm.switchModel(id);
              console.log(dim(`  now talking to ${llm.getActiveModelLabel()}\n`));
            } catch (e: unknown) {
              console.log(dim(`  could not switch: ${e instanceof Error ? e.message : String(e)}\n`));
            }
            return ask();
          }

          try {
            const { meta } = await llm.generalChat(input, tok => process.stdout.write(tok), { plainChat: true });
            console.log(`\n${dim(`· ${meta.tokensPerSecond.toFixed(0)} tok/s`)}\n`);
          } catch (e: unknown) {
            console.error(`\n${e instanceof Error ? e.message : String(e)}\n`);
          }
          ask();
        });
      };
      rl.on('close', () => { void llm.shutdown().finally(() => process.exit(0)); });
      ask();
    } catch (e: unknown) {
      console.error(e instanceof Error ? e.message : String(e));
      process.exitCode = 1;
    }
  });

// Default command - start interactive mode
if (process.argv.length === 2) {
  console.log('\n Quenderin - a personal AI that lives on your machine\n');
  console.log('Commands:');
  console.log('  quenderin chat            - Chat with a local model in this terminal');
  console.log('  quenderin chat -p "…"     - One answer, pipe-friendly (git diff | quenderin chat -p "review")');
  console.log('  quenderin models          - What is installed / downloadable');
  console.log('  quenderin download <id>   - Fetch a model (SHA-256 verified)');
  console.log('  quenderin dashboard       - Open the dashboard');
  console.log('  quenderin agent "<goal>"  - Start a new agent task');
  console.log('  quenderin --help          - Show all commands\n');
  process.exit(0);
}

program.parse(process.argv);