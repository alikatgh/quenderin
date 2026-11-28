import type { Writable } from 'node:stream';
import { setImmediate } from 'node:timers/promises';

/** Wait for stdout's ordered write callbacks through the trailing newline. */
export async function writePrintAnswer(
    output: Writable,
    generate: (onToken: (token: string) => void) => Promise<unknown>
): Promise<void> {
    let writeError: Error | null = null;
    const recordError = (error?: Error | null) => { writeError ??= error ?? null; };
    output.on('error', recordError);
    try {
        await generate(token => {
            if (!writeError) output.write(token, recordError);
        });
        await new Promise<void>(resolve => {
            output.write('\n', error => {
                recordError(error);
                resolve();
            });
        });
        if (writeError) throw writeError;
    } finally {
        // A failed write's callback can precede the corresponding stream error event.
        if (writeError) await setImmediate();
        output.off('error', recordError);
    }
}
