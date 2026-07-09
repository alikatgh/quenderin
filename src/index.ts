#!/usr/bin/env node
import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import readline from 'readline';
import { MODEL_CATALOG, MODELS_DIR } from './constants.js';
import { setLogLevel } from './utils/logger.js';
import { expandTilde } from './utils/paths.js';
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
import { OsascriptAutomation } from './services/capability/macAutomation.js';
import { InMemoryConsentStore, CapabilityTier } from './services/capability/capability.js';
import { createGovernedAgent } from './services/capability/desktopAgent.js';
import { macCapabilities } from './services/capability/macCapabilities.js';
import { fileCapabilities } from './services/capability/fileCapabilities.js';
import { FileAuditLedger, loadSkillMemory, saveSkillMemory, saveUndoJournal, loadUndoJournal, clearUndoJournal, loadCliConfig, CONFIG_PATH } from './services/capability/persistence.js';
import { formatHistory } from './services/capability/ledgerView.js';
import { replayUndo, UndoAction } from './services/capability/undo.js';
import { formatCapabilities } from './services/capability/catalog.js';
import { OsascriptMacUi } from './services/capability/macUi.js';
import { macUiCapabilities } from './services/capability/macUiCapabilities.js';
import { ExecFileRunner } from './services/capability/platformAutomation.js';
import { platformCapabilities } from './services/capability/platformCapabilities.js';

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
      // Q-278: `agent` is the LEGACY device-driving research loop (raw screenshot→coordinate
      // actions), which lacks the governed spine — no consent/preview/per-run approval/undo/ledger.
      // The governed agent is `quenderin do "<goal>"`. Make that explicit so nobody assumes parity.
      console.error(dim('Note: `agent` is the legacy research loop (no consent/approval/undo spine).'));
      console.error(dim('For the governed agent — asks before every change, undo, audit log — use `quenderin do "<goal>"`.'));
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

// ─── quenderin do — tell it to operate your Mac, governed the whole way ─────
// The first real end-user invocation of the whole capability stack: a local model plans,
// a terminal prompt is the approval dialog, Ctrl+C is the kill switch, undo is offered at
// the end. macOS-only for now (the mac.* capabilities). Nothing leaves the machine.
program
  .command('do')
  .description('Tell Quenderin to do something on your Mac — it asks before every change.')
  .argument('<goal>', 'what you want done, e.g. "remind me to call the dentist"')
  .option('-m, --model <id>', 'model to plan with (see `quenderin models`)')
  .option('-w, --workspace <dir>', 'a folder the agent may organize (enables fs.list/collect/move/organize/rename/trash/read/write)')
  .option('-s, --max-steps <n>', 'how many steps the agent may take (default 8; raise for multi-item tasks)')
  .option('-g, --gui', 'allow clicking/typing in any macOS app via accessibility (needs the Accessibility permission)')
  .option('-n, --dry-run', 'show exactly what it would do — read for real, but change nothing')
  .option('-y, --yes', 'auto-approve reversible changes (still asks for app control / GUI)')
  .option('-t, --think', 'reason before each step (better tool choice on tricky goals, but slower)')
  .action(async (goal: string, options: { model?: string; workspace?: string; maxSteps?: string; gui?: boolean; dryRun?: boolean; yes?: boolean; think?: boolean }) => {
    setLogLevel('error');
    const mac = new OsascriptAutomation();
    // Config file supplies defaults; a CLI flag always overrides it (flag > config > built-in).
    const config = loadCliConfig();
    const workspaceOpt = options.workspace ?? config.workspace;
    const guiEnabled = options.gui ?? config.gui ?? false;
    const modelId = options.model ?? config.model;
    let workspaceDir: string | null = null;
    if (workspaceOpt) {
      // Expand a leading ~ (a quoted flag or a config value isn't shell-expanded) before resolving.
      workspaceDir = path.resolve(expandTilde(workspaceOpt));
      if (!fs.existsSync(workspaceDir) || !fs.statSync(workspaceDir).isDirectory()) {
        console.error(`Workspace "${workspaceOpt}" is not a folder.`);
        process.exitCode = 1;
        return;
      }
    }
    // Windows/Linux OS automation (the win.*/linux.* libraries) — the mission's reach beyond
    // macOS. The runner is argv-only with fixed commands, so there is no interpolation to escape.
    const shell = new ExecFileRunner();
    if (!mac.available() && !shell.available() && !workspaceDir) {
      console.error('`quenderin do` needs macOS/Windows/Linux (for OS actions) or --workspace <dir> (for file tasks).');
      process.exitCode = 1;
      return;
    }
    // Step budget: default 8, clamp to [1, 50]. The loop guard + per-run approval already bound a
    // run; the ceiling is just a runaway backstop. A multi-item chore ("friend 20 users") needs more.
    let maxSteps = config.maxSteps ?? 8;
    if (options.maxSteps !== undefined) {
      const n = parseInt(options.maxSteps, 10);
      if (Number.isNaN(n)) { console.error('--max-steps must be a number.'); process.exitCode = 1; return; }
      maxSteps = n;
    }
    maxSteps = Math.min(50, Math.max(1, maxSteps));
    const llm = new LlmService();
    try {
      if (modelId) {
        if (!MODEL_CATALOG.some(m => m.id === modelId)) {
          console.error(`Unknown model "${modelId}". Run \`quenderin models\`.`);
          process.exitCode = 1;
          return;
        }
        await llm.switchModel(modelId);
      }

      const consent = new InMemoryConsentStore();
      // The per-change terminal prompt is the real gate here, so grant the capabilities in play.
      if (mac.available()) macCapabilities(mac).forEach(c => consent.setGranted(c.name, true));
      if (shell.available()) platformCapabilities(shell).forEach(c => consent.setGranted(c.name, true));
      if (workspaceDir) fileCapabilities(() => workspaceDir).forEach(c => consent.setGranted(c.name, true));
      const macUi = guiEnabled && mac.available() ? new OsascriptMacUi(mac) : undefined;
      if (macUi) macUiCapabilities(macUi).forEach(c => consent.setGranted(c.name, true));

      const ac = new AbortController();
      process.once('SIGINT', () => { console.log(dim('\n(stopping — finishing the current step)')); ac.abort(); });

      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      const approve = (preview: { summary: string; tier?: number }): Promise<boolean> => {
        // --yes auto-approves REVERSIBLE actions (≤ T2), but app-driving / GUI (T3) is the highest
        // blast radius, so it still asks — you can't rubber-stamp clicking around your apps.
        if (options.yes && (preview.tier ?? 0) < CapabilityTier.AppAction) {
          console.log(dim(`  auto-approved: ${preview.summary}`));
          return Promise.resolve(true);
        }
        const note = options.yes ? dim(' (app control — approving each one even with --yes)') : '';
        return new Promise(res => rl.question(`\n${bold(preview.summary)}${note}\n  Allow? [y/N] `, a => res(/^y(es)?$/i.test(a.trim()))));
      };

      // Persisted across runs: the ledger (review what it's done) and skill memory (it gets
      // better at what you repeat). Both under ~/.quenderin/, nothing leaves the machine.
      const memory = loadSkillMemory();
      const agent = createGovernedAgent({
        llm,
        mac: mac.available() ? mac : undefined,
        macUi,
        shell: shell.available() ? shell : undefined,
        workspace: workspaceDir ? () => workspaceDir : undefined,
        consent, approve, signal: ac.signal, ledger: new FileAuditLedger(), memory, maxSteps,
        dryRun: options.dryRun ?? false,
        deliberate: options.think ?? false,
      });
      if (options.dryRun) console.log(dim('  dry run — reading for real, changing nothing.'));
      console.log(`\n${bold('Quenderin')} ${dim('— on-device · nothing leaves this machine')}\n`);
      // Stream each step as it happens, so a long run isn't a silent wait — you watch it work.
      const result = await agent.run(goal, step => console.log(dim(`· ${step}`)));
      saveSkillMemory(memory);   // remember what worked for next time

      if (result.answer) console.log(`\n${result.answer}`);
      else {
        const why: Record<string, string> = {
          stalled: "the model got stuck repeating itself — try rephrasing the goal, or a bigger model with `-m`",
          maxSteps: "reached the step limit before finishing — try a smaller, more specific goal",
          planError: "the model's reply couldn't be parsed — try again, or a bigger model with `-m`",
          cancelled: 'stopped at your request',
        };
        console.log(dim(`\n(${why[result.halt] ?? result.halt})`));
      }

      // Capture what could be reversed BEFORE undoAll() drains the session.
      const undoable = agent.undoLog();
      if (undoable.length > 0) {
        const wantsUndo = await new Promise<boolean>(res =>
          rl.question(dim('\nUndo everything this task changed? [y/N] '), a => res(/^y(es)?$/i.test(a.trim()))));
        if (wantsUndo) {
          console.log(await agent.undoAll());
          clearUndoJournal();   // reversed now — nothing left for a later `quenderin undo`
        } else {
          // Persist it so `quenderin undo` can still reverse this task later (even in a new session).
          // fs.* reversals need the workspace folder, so attach it.
          const journal: UndoAction[] = undoable.map(a =>
            a.capability.startsWith('fs.') && workspaceDir ? { ...a, workspace: workspaceDir } : a);
          saveUndoJournal(journal);
          console.log(dim('\nLater? Run `quenderin undo` to reverse this task.'));
        }
      }
      rl.close();
      await llm.shutdown();
      process.exit(0);
    } catch (e: unknown) {
      console.error(e instanceof Error ? e.message : String(e));
      process.exitCode = 1;
    }
  });

program
  .command('config')
  .description('Show the config file that supplies `quenderin do` defaults (edit it to set them).')
  .action(() => {
    const cfg = loadCliConfig();
    console.log(`\nConfig file: ${bold(CONFIG_PATH)}`);
    if (Object.keys(cfg).length === 0) {
      console.log(dim('  (none set — CLI flags use the built-in defaults)'));
      console.log(dim('  Create it with e.g.: {"workspace": "~/Downloads", "gui": true, "model": "gemma-4-12b"}'));
    } else {
      for (const [k, v] of Object.entries(cfg)) console.log(`  ${k.padEnd(10)} ${dim(String(v))}`);
      console.log(dim('\n  A CLI flag always overrides these.'));
    }
    console.log('');
  });

program
  .command('capabilities')
  .alias('caps')
  .description('List everything Quenderin can do — the governed capability library.')
  .action(() => {
    const mac = new OsascriptAutomation();
    const shell = new ExecFileRunner();
    const caps = [
      ...(mac.available() ? [...macCapabilities(mac), ...macUiCapabilities(new OsascriptMacUi(mac))] : []),
      ...platformCapabilities(shell),
      ...fileCapabilities(() => null),
    ];
    console.log(formatCapabilities(caps, { color: process.stdout.isTTY }));
  });

program
  .command('undo')
  .description('Reverse the changes from your last `quenderin do` task — even in a new session.')
  .action(async () => {
    const actions = loadUndoJournal();
    if (actions.length === 0) {
      console.log('Nothing to undo — no reversible task on record.');
      return;
    }
    console.log('');
    console.log(await replayUndo(actions, new OsascriptAutomation()));
    clearUndoJournal();   // reversed — don't let a second `undo` double-apply
    console.log('');
  });

program
  .command('history')
  .description('Review what the agent has done on this machine — the local, private audit ledger.')
  .option('-n, --limit <n>', 'how many recent entries to show', '20')
  .action((options: { limit?: string }) => {
    const limit = Math.max(1, parseInt(options.limit ?? '20', 10) || 20);
    const entries = new FileAuditLedger().entries();
    console.log('');
    console.log(formatHistory(entries, { limit, color: process.stdout.isTTY }));
    console.log('');
  });

// Default command - start interactive mode
if (process.argv.length === 2) {
  console.log('\n Quenderin - a personal AI that lives on your machine\n');
  console.log('Commands:');
  console.log('  quenderin do "<goal>"     - Tell it to do something on your Mac (asks before every change)');
  console.log('  quenderin capabilities    - List everything Quenderin can do');
  console.log('  quenderin config          - Show the defaults `do` uses (workspace, model, gui…)');
  console.log('  quenderin history         - Review everything the agent has done (the local audit log)');
  console.log('  quenderin undo            - Reverse your last `do` task (works in a new session)');
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