import type { Command } from 'commander';
import { ImageGenerationService } from '../services/imageGeneration.js';
import { expandTilde } from '../utils/paths.js';

export function registerImageCommands(program: Command): void {
    const image = program.command('image')
        .description('Experimental local image generation with the pinned FLUX 3 / MOSS pipeline.')
        .addHelpText('after', '\nPrepare every catalog component in one directory first. This CLI does not download files or accept publisher terms. FLUX files require your own publisher access and license review. Generation needs 24 GiB available memory and an installed pinned native runtime. FLUX prompts must already be expanded full-scene captions; reference-image input is not exposed by this CLI.');
    image.command('models').description('List image presets, required filenames and publisher licenses.')
        .action(() => {
            try {
                const service = new ImageGenerationService();
                console.log('Experimental source integration; full-model inference has not been validated.');
                for (const model of service.models()) {
                    console.log(`\n${model.id} — ${model.label}\n  License: ${model.license}\n  ${model.licenseUrl}`);
                    if (model.requiresPublisherAccess) console.log('  Obtain gated files yourself after reviewing publisher terms.');
                    for (const component of model.components) console.log(`  ${component.localFilename} (${component.bytes} bytes)`);
                    if (model.promptRequirement) console.log(`  Prompt: ${model.promptRequirement}`);
                }
            } catch (error) { fail(error); }
        });
    image.command('verify').description('Verify the complete prepared component set by exact size and SHA-256.')
        .requiredOption('--model <id>', 'Image preset from `quenderin image models`')
        .requiredOption('--directory <path>', 'Directory containing all prepared component filenames')
        .action(async (options: { model: string; directory: string }) => {
            const controller = new AbortController();
            const cancel = (): void => controller.abort();
            process.once('SIGINT', cancel);
            try {
                const result = await new ImageGenerationService().verify(options.model, expandTilde(options.directory), controller.signal);
                console.log(`Verified ${result.components} components (${result.bytes} bytes) for ${result.model}. Inference remains unvalidated.`);
            } catch (error) { fail(error); }
            finally { process.removeListener('SIGINT', cancel); }
        });
    image.command('generate').description('Generate one new PNG locally; the native generation process has a 15-minute limit.')
        .requiredOption('--model <id>', 'Image preset from `quenderin image models`')
        .requiredOption('--directory <path>', 'Directory containing every verified component')
        .requiredOption('--prompt <caption>', 'Full scene caption; FLUX requires a prompt expanded beforehand')
        .requiredOption('--output <path>', 'New PNG filename in an existing directory; never overwrites')
        .option('--runtime <path>', 'Prepared pinned quenderin-diffusion-cli (or QUENDERIN_IMAGE_RUNTIME)')
        .action(async (options: { model: string; directory: string; prompt: string; output: string; runtime?: string }) => {
            const controller = new AbortController();
            const cancel = (): void => controller.abort();
            process.once('SIGINT', cancel);
            process.once('SIGTERM', cancel);
            try {
                const result = await new ImageGenerationService().generate({ ...options,
                    directory: expandTilde(options.directory), output: expandTilde(options.output),
                    runtime: options.runtime ? expandTilde(options.runtime) : undefined,
                    signal: controller.signal,
                    onProgress: progress => process.stderr.write(`Image step ${progress.step}/${progress.steps}\n`),
                });
                console.log(result.path);
            } catch (error) { fail(error); }
            finally { process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel); }
        });
}

function fail(error: unknown): void {
    console.error(error instanceof Error ? error.message : 'Local image operation failed.');
    process.exitCode = 1;
}
