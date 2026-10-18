// Tiny process-protocol fixture. Does not load a model or decode an image.
const lock = require('../../shared/prism-runtime.json');
const mode = process.env.QUENDERIN_VISION_FIXTURE;
if (process.argv.includes('--abi')) {
    console.log(JSON.stringify({ abi: 1, revision: lock.revision, visionPatchSha256: mode === 'stale' ? 'stale' : lock.visionPatch.sha256 }));
} else {
    let input = '';
    process.stdin.on('data', chunk => { input += chunk; if (input.length > 65536) process.exit(3); });
    process.stdin.on('end', () => {
        const request = JSON.parse(input);
        if (request.prompt !== 'Synthetic image question' || request.max_tokens !== 512 || request.context_size !== 4096
            || !request.model_path.endsWith('.gguf') || !request.projector_path.endsWith('.gguf') || request.image_path !== 'fixture-only.png') process.exit(3);
        if (mode === 'hang') { setInterval(() => {}, 1000); return; }
        if (mode === 'utf8') { process.stdout.write(Buffer.from([0xff])); return; }
        if (mode === 'large') { process.stdout.write('x'.repeat(600 * 1024)); return; }
        console.log(JSON.stringify({ type: 'token', text: mode === 'private' ? '<think>hidden' : 'Synthetic process answer' }));
        console.log(JSON.stringify({ type: 'done', tokens: 3 }));
        if (mode === 'extra') console.log(JSON.stringify({ type: 'token', text: 'after completion' }));
    });
}
