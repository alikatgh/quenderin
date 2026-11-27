import { describe, expect, it } from 'vitest';
import { isModelInstalled, planRun, requiredModelFilenames } from '../src/commands/run.js';

describe('planRun', () => {
  it('returns an error matching download/chat style for an unknown model id', () => {
    const plan = planRun({
      id: 'does-not-exist',
      promptArgs: [],
      stdinIsTTY: true,
      installed: false,
      known: false,
      allowDownload: true,
    });
    expect(plan).toEqual({
      kind: 'error',
      message: 'Unknown model "does-not-exist". Run `quenderin models` for the list.',
    });
  });

  it('rejects an unknown model even when installed or --no-download is set', () => {
    const plan = planRun({
      id: 'bogus',
      promptArgs: ['hello'],
      stdinIsTTY: false,
      installed: true,
      known: false,
      allowDownload: false,
    });
    expect(plan.kind).toBe('error');
    if (plan.kind === 'error') {
      expect(plan.message).toContain('Unknown model "bogus"');
      expect(plan.message).toContain('quenderin models');
    }
  });

  it('returns repl when installed, TTY stdin, and no prompt args', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: [],
      stdinIsTTY: true,
      installed: true,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({ kind: 'repl' });
  });

  it('returns repl when promptArgs are whitespace only and stdin is TTY', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: ['   ', '\t'],
      stdinIsTTY: true,
      installed: true,
      known: true,
      allowDownload: false,
    });
    expect(plan).toEqual({ kind: 'repl' });
  });

  it('returns print with space-joined prompt when installed and prompt args are given', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: ['why', 'is', 'the', 'sky', 'blue?'],
      stdinIsTTY: true,
      installed: true,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({ kind: 'print', prompt: 'why is the sky blue?' });
  });

  it('returns print with empty arg prompt when installed and stdin is piped without positional args', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: [],
      stdinIsTTY: false,
      installed: true,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({ kind: 'print', prompt: '' });
  });

  it('returns print with arg prompt when installed and both positional prompt and piped stdin exist', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: ['Review', 'this', 'diff'],
      stdinIsTTY: false,
      installed: true,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({ kind: 'print', prompt: 'Review this diff' });
  });

  it('returns an error with download hint when not installed and allowDownload is false (--no-download)', () => {
    const plan = planRun({
      id: 'qwen3-4b',
      promptArgs: ['hi'],
      stdinIsTTY: true,
      installed: false,
      known: true,
      allowDownload: false,
    });
    expect(plan).toEqual({
      kind: 'error',
      message: 'Model "qwen3-4b" is not installed. Run `quenderin download qwen3-4b` first.',
    });
  });

  it('returns download-then repl when not installed, allowDownload is true, TTY, and no prompt', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: [],
      stdinIsTTY: true,
      installed: false,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({ kind: 'download-then', next: 'repl' });
  });

  it('returns download-then print with prompt when not installed, allowDownload is true, and prompt given', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: ['why is the sky blue?'],
      stdinIsTTY: true,
      installed: false,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({
      kind: 'download-then',
      next: 'print',
      prompt: 'why is the sky blue?',
    });
  });

  it('returns download-then print without prompt when not installed and stdin is piped with no args', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: [],
      stdinIsTTY: false,
      installed: false,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({ kind: 'download-then', next: 'print' });
  });

  it('returns download-then print with prompt when not installed and both stdin and prompt args exist', () => {
    const plan = planRun({
      id: 'llama32-1b',
      promptArgs: ['summarize', 'this'],
      stdinIsTTY: false,
      installed: false,
      known: true,
      allowDownload: true,
    });
    expect(plan).toEqual({
      kind: 'download-then',
      next: 'print',
      prompt: 'summarize this',
    });
  });
});

describe('isModelInstalled (single-file and multipart shard completeness)', () => {
  it('checks the single filename for non-multipart models', () => {
    const model = { filename: 'qwen3-4b.Q4_K_M.gguf' };
    expect(requiredModelFilenames(model)).toEqual(['qwen3-4b.Q4_K_M.gguf']);
    expect(isModelInstalled(model, f => f === 'qwen3-4b.Q4_K_M.gguf')).toBe(true);
    expect(isModelInstalled(model, () => false)).toBe(false);
  });

  it('requires every shard of a multipart model before skipping download in planRun', () => {
    const multipart = {
      filename: 'Beam-1.0-00001-of-00004.gguf',
      artifacts: [
        { filename: 'Beam-1.0-00001-of-00004.gguf' },
        { filename: 'Beam-1.0-00002-of-00004.gguf' },
        { filename: 'Beam-1.0-00003-of-00004.gguf' },
        { filename: 'Beam-1.0-00004-of-00004.gguf' },
      ],
    };
    expect(requiredModelFilenames(multipart)).toHaveLength(4);

    // Only shard 1 present, shard 2 missing -> NOT installed -> run must download.
    const partialOnDisk = new Set([
      'Beam-1.0-00001-of-00004.gguf',
      'Beam-1.0-00003-of-00004.gguf',
      'Beam-1.0-00004-of-00004.gguf',
    ]);
    expect(isModelInstalled(multipart, f => partialOnDisk.has(f))).toBe(false);
    expect(planRun({
      id: 'beam-1.0-501b-a23b-ud-iq2-xxs',
      promptArgs: ['hi'],
      stdinIsTTY: true,
      installed: isModelInstalled(multipart, f => partialOnDisk.has(f)),
      known: true,
      allowDownload: true,
    })).toEqual({ kind: 'download-then', next: 'print', prompt: 'hi' });

    // All 4 shards present -> installed -> run skips download.
    const completeOnDisk = new Set([
      'Beam-1.0-00001-of-00004.gguf',
      'Beam-1.0-00002-of-00004.gguf',
      'Beam-1.0-00003-of-00004.gguf',
      'Beam-1.0-00004-of-00004.gguf',
    ]);
    expect(isModelInstalled(multipart, f => completeOnDisk.has(f))).toBe(true);
    expect(planRun({
      id: 'beam-1.0-501b-a23b-ud-iq2-xxs',
      promptArgs: ['hi'],
      stdinIsTTY: true,
      installed: isModelInstalled(multipart, f => completeOnDisk.has(f)),
      known: true,
      allowDownload: true,
    })).toEqual({ kind: 'print', prompt: 'hi' });
  });
});
