import type { Command } from 'commander';
import {
    HexSpeechAdapter,
    type DictationFormatOptions,
    type SpeechNativeRequest,
    type HexHostTranscribeRequest,
} from '../services/hexSpeechAdapter.js';
import { expandTilde } from '../utils/paths.js';

export function registerVoiceCommands(program: Command): void {
    const voice = program.command('voice')
        .description('Experimental local speech-to-text powered by the pinned anomalyco/hex and transcribe.cpp integration.')
        .addHelpText('after', '\nPrepare the catalog GGUF model (and optional Silero VAD v6.2) in a local directory first, or connect to a loopback Hex daemon (`hex service --embedded`). This CLI never downloads model weights automatically.');

    voice.command('models')
        .description('List all pinned Hex / transcribe.cpp speech models, languages, and licenses.')
        .action(() => {
            try {
                const adapter = new HexSpeechAdapter();
                const vad = adapter.vad();
                console.log('Experimental source integration; full-model speech inference and microphone tests remain unvalidated.');
                console.log(`\nVAD: ${vad.id} — ${vad.label} (${vad.bytes} bytes)\n  File: ${vad.localFilename}\n  License: ${vad.license}`);
                for (const model of adapter.models()) {
                    const sizeLabel = model.bytes ? `${model.bytes} bytes` : 'on-device framework';
                    const speed = model.realtime ? `, ${model.realtime} RT` : '';
                    const wer = model.wordErrorRate !== undefined ? `, WER ${model.wordErrorRate}%` : '';
                    console.log(`\n${model.id} — ${model.label} (${model.engine}, ${model.architecture}${speed}${wer})`);
                    console.log(`  Languages (${model.languages.length}): ${model.languages.slice(0, 8).join(', ')}${model.languages.length > 8 ? ', ...' : ''}`);
                    console.log(`  Artifact: ${model.localFilename ?? 'macOS Apple Speech'} (${sizeLabel})`);
                    console.log(`  License: ${model.license}`);
                }
            } catch (error) {
                fail(error);
            }
        });

    voice.command('verify')
        .description('Verify a prepared speech model (and optional Silero VAD v6.2) by exact byte size and SHA-256.')
        .requiredOption('--model <id>', 'Speech model id from `quenderin voice models`')
        .requiredOption('--directory <path>', 'Directory containing the prepared GGUF artifact(s)')
        .option('--vad', 'Also require and verify silero-vad-v6.2-F32.gguf in the same directory')
        .action(async (options: { model: string; directory: string; vad?: boolean }) => {
            const controller = new AbortController();
            const cancel = (): void => controller.abort();
            process.once('SIGINT', cancel);
            try {
                const result = await new HexSpeechAdapter().verify(
                    options.model,
                    expandTilde(options.directory),
                    { includeVad: Boolean(options.vad), signal: controller.signal },
                );
                const vadNote = result.vadVerified ? ' + Silero VAD v6.2' : '';
                console.log(`Verified ${result.model}${vadNote} (${result.bytes} bytes). Inference remains unvalidated.`);
            } catch (error) {
                fail(error);
            } finally {
                process.removeListener('SIGINT', cancel);
            }
        });

    voice.command('transcribe')
        .description('Transcribe a 16 kHz mono 16-bit PCM WAV file via quenderin-speech-cli or loopback Hex host.')
        .requiredOption('--model <id>', 'Speech model id from `quenderin voice models`')
        .requiredOption('--wav <path>', 'Canonical path to a 16 kHz mono 16-bit PCM .wav file')
        .option('--directory <path>', 'Directory containing the verified GGUF artifact (required for native CLI)')
        .option('--runtime <path>', 'Prepared pinned quenderin-speech-cli (or QUENDERIN_SPEECH_RUNTIME)')
        .option('--hex-discovery <path>', 'Path to Hex local-api.json loopback discovery file')
        .option('--hex-bin <path>', 'Path to Hex binary supporting `service --embedded`')
        .option('--hex-url <url>', 'Explicit loopback Hex http://127.0.0.1:<port> URL (paired with HEX_API_TOKEN or --hex-token)')
        .option('--hex-token <token>', 'Bearer token for explicit --hex-url')
        .option('--vad', 'Enable Silero VAD v6.2 pre-filtering from --directory (native CLI)')
        .option('--language <code>', 'ISO language hint (e.g. en, fr, de)')
        .option('--prompt <text>', 'Optional transcription context prompt (max 8 KiB)')
        .option('--vocab <terms>', 'Comma-separated custom vocabulary spelling terms (max 100)')
        .option('--threads <n>', 'Worker threads (1-8)', '4')
        .option('--format', 'Apply Hex dictation cleanup (spoken punctuation, filler removal, vocabulary)')
        .option('--json', 'Print full structured JSON result to stdout')
        .action(async (options: {
            model: string;
            wav: string;
            directory?: string;
            runtime?: string;
            hexDiscovery?: string;
            hexBin?: string;
            hexUrl?: string;
            hexToken?: string;
            vad?: boolean;
            language?: string;
            prompt?: string;
            vocab?: string;
            threads?: string;
            format?: boolean;
            json?: boolean;
        }) => {
            const controller = new AbortController();
            const cancel = (): void => controller.abort();
            process.once('SIGINT', cancel);
            process.once('SIGTERM', cancel);
            try {
                const adapter = new HexSpeechAdapter();
                const vocab = options.vocab
                    ? options.vocab.split(',').map(v => v.trim()).filter(Boolean)
                    : undefined;
                const format: DictationFormatOptions | undefined = (options.format || vocab?.length)
                    ? {
                        vocabulary: vocab,
                        removeFillerWords: Boolean(options.format),
                        spokenPunctuation: Boolean(options.format),
                        language: options.language,
                    }
                    : undefined;
                const wav = expandTilde(options.wav);
                let result;
                if (options.hexDiscovery || options.hexBin || options.hexUrl) {
                    const hexReq: HexHostTranscribeRequest = {
                        model: options.model,
                        wav,
                        hexDiscoveryPath: options.hexDiscovery ? expandTilde(options.hexDiscovery) : undefined,
                        hexExecutable: options.hexBin ? expandTilde(options.hexBin) : undefined,
                        hexUrl: options.hexUrl,
                        hexToken: options.hexToken ?? process.env.HEX_API_TOKEN,
                        language: options.language,
                        format,
                        signal: controller.signal,
                    };
                    result = await adapter.transcribeWithHexHost(hexReq);
                } else {
                    if (!options.directory) {
                        throw new Error('Provide --directory for native CLI transcription, or specify --hex-discovery / --hex-bin / --hex-url.');
                    }
                    const nativeReq: SpeechNativeRequest = {
                        model: options.model,
                        directory: expandTilde(options.directory),
                        wav,
                        vad: Boolean(options.vad),
                        runtime: options.runtime ? expandTilde(options.runtime) : undefined,
                        language: options.language,
                        prompt: options.prompt,
                        threads: Math.max(1, Math.min(8, parseInt(options.threads ?? '4', 10) || 4)),
                        timestamps: Boolean(options.json),
                        format,
                        signal: controller.signal,
                    };
                    result = await adapter.transcribeWithCli(nativeReq);
                }
                if (options.json) {
                    console.log(JSON.stringify(result));
                } else {
                    console.log(result.text);
                }
            } catch (error) {
                fail(error);
            } finally {
                process.removeListener('SIGINT', cancel);
                process.removeListener('SIGTERM', cancel);
            }
        });
}

function fail(error: unknown): void {
    console.error(error instanceof Error ? error.message : 'Local speech operation failed.');
    process.exitCode = 1;
}
