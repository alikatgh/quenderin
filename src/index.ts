import { Command } from 'commander';
import { generateCode } from './generator.js';

const program = new Command();

program
  .name('quenderin-poc')
  .description('Proof-of-concept for a local code generation CLI.')
  .version('0.0.1');

program
  .command('add')
  .description('Generate code from a natural language prompt.')
  .argument('<prompt>', 'The feature to generate in plain english')
  .action(async (prompt: string) => {
    try {
      const generatedCode = await generateCode(prompt);
      console.log("\n--- Generated Code ---\n");
      console.log(generatedCode);
      console.log("\n----------------------\n");
    } catch (e) {
      console.error("Failed to generate code.");
    }
  });

program.parse(process.argv);