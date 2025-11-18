#!/usr/bin/env node
import { Command } from 'commander';
import { generateCodeSimple, testConnection } from './unified-generator.js';
import { saveConfig } from './config.js';
import { autoDetectProvider, OllamaProvider } from './providers.js';
import { interactiveSetup } from './interactive-setup.js';
import fs from 'fs';
import path from 'path';

const program = new Command();

program
  .name('quenderin')
  .description('Local LLM-powered code generation toolchain')
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

// Generate code command
program
  .command('add')
  .description('Generate code from a natural language prompt')
  .argument('<prompt>', 'The feature to generate in plain English')
  .option('-o, --output <file>', 'Output file path (default: stdout)')
  .option('-t, --tokens <number>', 'Max tokens to generate', '2048')
  .action(async (prompt: string, options) => {
    try {
      const generatedCode = await generateCodeSimple(prompt, {
        maxTokens: parseInt(options.tokens)
      });

      if (options.output) {
        const outputPath = path.resolve(options.output);
        fs.mkdirSync(path.dirname(outputPath), { recursive: true });
        fs.writeFileSync(outputPath, generatedCode);
        console.log(`\n✅ Code written to: ${outputPath}\n`);
      } else {
        console.log('\n' + '='.repeat(60));
        console.log('Generated Code:');
        console.log('='.repeat(60) + '\n');
        console.log(generatedCode);
        console.log('\n' + '='.repeat(60) + '\n');
      }
    } catch (e: any) {
      console.error('\n❌ Error:', e.message);
      console.error('\nTroubleshooting:');
      console.error('  1. Make sure you have downloaded a model');
      console.error('  2. Check models/ directory has a .gguf file');
      console.error('  3. Run "quenderin model-info" to see available models\n');
      process.exit(1);
    }
  });

// Show help if no command provided
if (process.argv.length === 2) {
  program.help();
}

program.parse(process.argv);