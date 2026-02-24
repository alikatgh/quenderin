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

const program = new Command();

program
  .name('quenderin-poc')
  .description('An offline autonomous agent control')
  .version('0.0.1');

// Initialize command
program
  .command('init')
  .description('Initialize Quenderin in the current project')
  .action(async () => {
    console.log('\n🚀 Initializing Quenderin...\n');

    const modelsDir = path.join(process.cwd(), 'models');
    const genDir = path.join(process.cwd(), 'src', 'gen');
    const promptsDir = path.join(process.cwd(), 'prompts');

    // Create directories
    if (!fs.existsSync(modelsDir)) {
      fs.mkdirSync(modelsDir, { recursive: true });
      console.log('✓ Created models/ directory');
    } else {
      console.log('✓ models/ directory already exists');
    }

    if (!fs.existsSync(genDir)) {
      fs.mkdirSync(genDir, { recursive: true });
      console.log('✓ Created src/gen/ directory');
    } else {
      console.log('✓ src/gen/ directory already exists');
    }

    if (!fs.existsSync(promptsDir)) {
      fs.mkdirSync(promptsDir, { recursive: true });
      console.log('✓ Created prompts/ directory');

      // Create example prompt
      const examplePrompt = `# Example Feature Prompt

Describe your feature in natural language here.

## Requirements
- Bullet point your requirements
- Be specific about inputs and outputs
- Mention any edge cases

## Example Usage
\`\`\`typescript
// Show how you want to use the generated code
\`\`\`
`;
      fs.writeFileSync(
        path.join(promptsDir, 'example.md'),
        examplePrompt
      );
      console.log('✓ Created example prompt in prompts/example.md');
    } else {
      console.log('✓ prompts/ directory already exists');
    }

    // Create .gitignore if it doesn't exist
    const gitignorePath = path.join(process.cwd(), '.gitignore');
    const gitignoreContent = `
# Quenderin
models/
src/gen/
`;

    if (!fs.existsSync(gitignorePath)) {
      fs.writeFileSync(gitignorePath, gitignoreContent);
      console.log('✓ Created .gitignore');
    } else {
      const currentGitignore = fs.readFileSync(gitignorePath, 'utf-8');
      if (!currentGitignore.includes('models/')) {
        fs.appendFileSync(gitignorePath, gitignoreContent);
        console.log('✓ Updated .gitignore');
      } else {
        console.log('✓ .gitignore already configured');
      }
    }

    console.log('\n📦 Next steps:');
    console.log('  Run: quenderin setup');
    console.log('  This will help you connect to an LLM in seconds!\n');
  });

// Interactive setup command
program
  .command('setup')
  .description('Interactive setup - connect to an LLM in seconds!')
  .action(async () => {
    await interactiveSetup();
  });

// UI setup command - drag and drop interface
program
  .command('ui')
  .description('Open web UI for super simple drag-and-drop LLM setup')
  .option('-p, --port <number>', 'Port to run the UI server on', '3777')
  .action(async (options) => {
    const port = parseInt(options.port);
    await startUIServer(port);
  });

// Test connection command
program
  .command('test')
  .description('Test LLM connection')
  .action(async () => {
    console.log('\n🔌 Testing LLM connection...\n');
    const success = await testConnection();
    if (success) {
      console.log('\n✅ Ready to generate code!\n');
      process.exit(0);
    } else {
      console.log('\n❌ Connection failed. Run: quenderin setup\n');
      process.exit(1);
    }
  });

// Model info command
program
  .command('model-info')
  .description('Show information about available models')
  .action(() => {
    const modelsDir = path.join(process.cwd(), 'models');

    if (!fs.existsSync(modelsDir)) {
      console.log('\n❌ Models directory not found.');
      console.log('Run "quenderin init" first.\n');
      return;
    }

    const files = fs.readdirSync(modelsDir);
    const ggufFiles = files.filter(f => f.endsWith('.gguf'));

    if (ggufFiles.length === 0) {
      console.log('\n📭 No models found in models/ directory.');
      console.log('Download a model to get started.');
      console.log('See models/README.md for instructions.\n');
      return;
    }

    console.log('\n📊 Available Models:\n');
    ggufFiles.forEach(file => {
      const filePath = path.join(modelsDir, file);
      const stats = fs.statSync(filePath);
      const sizeMB = (stats.size / (1024 * 1024)).toFixed(2);
      console.log(`  • ${file}`);
      console.log(`    Size: ${sizeMB} MB`);
      console.log(`    Path: ${filePath}\n`);
    });
  });

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
      await startDashboardServer(parseInt(options.port, 10));
    } catch (e: any) {
      console.error("Failed to start dashboard server:", e.message);
    }
  });

program
  .command('add')
  .description('Generate code from a natural language prompt')
  .argument('<prompt>', 'The feature to generate in plain English')
  .option('-o, --output <file>', 'Output file path (default: stdout)')
  .option('-t, --tokens <number>', 'Max tokens to generate', '2048')
  .action(async (prompt: string, options) => {
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

// Interactive chat mode
program
  .command('chat')
  .description('Interactive mode - keep generating code in a conversation')
  .action(async () => {
    // Check if setup is needed
    const config = loadConfig();
    const hasConfig = config.provider || config.apiKey || fs.existsSync(path.join(process.cwd(), 'quenderin.json'));

    if (!hasConfig) {
      console.log('👋 First time using Quenderin? Let\'s get you started!\n');
      const setupSuccess = await quickSetup();
      if (!setupSuccess) {
        console.log('\n⚠️  Setup cancelled. Run "quenderin setup" when ready.\n');
        process.exit(0);
      }
    }

    console.log('\n💬 Quenderin Chat Mode\n');
    console.log('Type your prompts to generate code. Type "exit" or press Ctrl+C to quit.\n');
    console.log('='.repeat(60) + '\n');

    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout
    });

    const ask = () => {
      rl.question('📝 What code do you want to generate?\n> ', async (prompt) => {
        if (!prompt || prompt.toLowerCase() === 'exit' || prompt.toLowerCase() === 'quit') {
          console.log('\n👋 Happy coding!\n');
          rl.close();
          process.exit(0);
        }

        try {
          console.log('\n🤖 Generating...\n');
          const generatedCode = await generateCodeSimple(prompt);
          console.log('='.repeat(60));
          console.log(generatedCode);
          console.log('='.repeat(60) + '\n');
        } catch (e: unknown) {
          const message = e instanceof Error ? e.message : 'Unknown error';
          console.error('❌ Error:', message, '\n');
        }

        ask(); // Continue the conversation
      });
    };

    ask();
  });

// Default command - start interactive mode
if (process.argv.length === 2) {
  console.log('\n⚡ Quenderin - Generate code from plain English\n');
  console.log('Commands:');
  console.log('  quenderin ui              - 🎨 Drag & drop web UI (super easy!)');
  console.log('  quenderin add "<prompt>"  - Generate code once');
  console.log('  quenderin chat            - Interactive chat mode');
  console.log('  quenderin setup           - Configure your LLM');
  console.log('  quenderin --help          - Show all commands\n');
  console.log('💡 Tip: Run "quenderin ui" for the easiest setup experience!\n');
  process.exit(0);
}

program.parse(process.argv);