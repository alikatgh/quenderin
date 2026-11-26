export interface InstallableModel {
  readonly filename: string;
  readonly artifacts?: readonly { readonly filename: string }[];
}

/**
 * Returns every filename that must exist on disk for `entry` to count as installed.
 * Multipart models (e.g. Beam, Muse) require every pinned shard, not just the first file.
 */
export function requiredModelFilenames(entry: InstallableModel): readonly string[] {
  if (entry.artifacts && entry.artifacts.length > 0) {
    return entry.artifacts.map(part => part.filename);
  }
  return [entry.filename];
}

/**
 * Returns true only when every required artifact file for `entry` is present on disk.
 */
export function isModelInstalled(
  entry: InstallableModel,
  fileExists: (filename: string) => boolean,
): boolean {
  return requiredModelFilenames(entry).every(filename => fileExists(filename));
}

export interface PlanRunInput {
  id: string;
  promptArgs: readonly string[];
  stdinIsTTY: boolean;
  installed: boolean;
  known: boolean;
  allowDownload: boolean;
}

export type RunPlan =
  | { kind: 'error'; message: string }
  | { kind: 'download-then'; next: 'print' | 'repl'; prompt?: string }
  | { kind: 'print'; prompt: string }
  | { kind: 'repl' };

/**
 * Pure planner for `quenderin run <id> [prompt...]`.
 * Decides whether to error, download first, run one-shot print mode, or start the interactive REPL.
 * Caller reads piped stdin when `next === 'print'` or `kind === 'print'`.
 */
export function planRun(input: PlanRunInput): RunPlan {
  const { id, promptArgs, stdinIsTTY, installed, known, allowDownload } = input;

  if (!known) {
    return {
      kind: 'error',
      message: `Unknown model "${id}". Run \`quenderin models\` for the list.`,
    };
  }

  const prompt = promptArgs.join(' ').trim();
  const isPrint = prompt.length > 0 || !stdinIsTTY;

  if (!installed) {
    if (!allowDownload) {
      return {
        kind: 'error',
        message: `Model "${id}" is not installed. Run \`quenderin download ${id}\` first.`,
      };
    }
    if (isPrint) {
      return prompt.length > 0
        ? { kind: 'download-then', next: 'print', prompt }
        : { kind: 'download-then', next: 'print' };
    }
    return { kind: 'download-then', next: 'repl' };
  }

  if (isPrint) {
    return { kind: 'print', prompt };
  }
  return { kind: 'repl' };
}
