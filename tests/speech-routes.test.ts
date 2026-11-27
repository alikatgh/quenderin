import { describe, it } from 'vitest';

/**
 * Stage 2 wires src/routes/speech.ts into src/app.ts. Use an in-process app
 * (the existing supertest-style helpers) with injected fake download/settings
 * implementations; no network, no model files.
 */
describe('speech API routes', () => {
    it.todo('GET /api/speech/models returns runtime version, recommended/accurate ids and all 29 rows');
    it.todo('GET /api/speech/models marks minEngine-newer models as needs-newer-engine');
    it.todo('POST /api/speech/downloads starts one download and returns the queued snapshot');
    it.todo('POST /api/speech/downloads rejects an unknown model with a typed error code');
    it.todo('POST /api/speech/downloads/:id/pause, /resume and /cancel return the new snapshot');
    it.todo('GET /api/speech/downloads/:id returns 404 before any download');
    it.todo('GET /api/speech/settings and PUT /api/speech/settings round-trip the saved choice');
    it.todo('PUT /api/speech/settings rejects an unknown modelId and non-boolean flags');
    it.todo('mutating speech routes require X-Auth-Token like the other API routes');
    it.todo('POST /api/speech/transcribe accepts only audio/wav and enforces the 64 MiB cap');
    it.todo('POST /api/speech/transcribe returns 413 above the cap before buffering');
    it.todo('POST /api/speech/transcribe returns 409 for an unsupported engine');
});
