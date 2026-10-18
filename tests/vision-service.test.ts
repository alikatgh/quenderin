import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { VisionService } from '../src/services/vision.js';
import { VISION_MODELS } from '../src/visionModels.js';
const worker = fileURLToPath(new URL('./fixtures/vision-worker.cjs', import.meta.url));
function service(mode = '') {
    return new VisionService(path.resolve('fixture-models'), () => 1024 ** 4, 'fixture-runtime',
        ((_file, args, options) => spawn(process.execPath, [worker, ...args], { ...options, env: { ...process.env, QUENDERIN_VISION_FIXTURE: mode } })) as typeof spawn);
}
const answer = (engine: VisionService, signal = new AbortController().signal) => engine.answer(VISION_MODELS[0].id, 'fixture-only.png', 'Synthetic image question', signal);
describe('vision worker process protocol, without model weights', () => {
    it('probes the exact compiled revision and carries the bounded request over stdin', async () => {
        await expect(answer(service())).resolves.toEqual({ text: 'Synthetic process answer', tokens: 3 });
    });
    it.each(['stale', 'utf8', 'large', 'private', 'extra'])('rejects a %s runtime or response', async mode => {
        await expect(answer(service(mode))).rejects.toThrow();
    });
    it('joins a cancelled child before making the process memory lease available again', async () => {
        const controller = new AbortController();
        const pending = answer(service('hang'), controller.signal);
        const failure = expect(pending).rejects.toThrow('cancelled');
        setTimeout(() => controller.abort(), 200);
        await failure;
        await expect(answer(service())).resolves.toMatchObject({ tokens: 3 });
    });
});
