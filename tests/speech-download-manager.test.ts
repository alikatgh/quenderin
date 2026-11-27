import { describe, it } from 'vitest';

/**
 * Stage 2 implements src/services/speech/downloadManager.ts with injected
 * fetch/fs/clock. Every test below must stay offline: fixtures only, zero
 * model weights, zero network.
 */
describe('speech download manager', () => {
    it.todo('streams to <filename>.part and reports bytes, percent and speed');
    it.todo('resumes from an existing .part with Range: bytes=<size>- and appends the 206 body');
    it.todo('restarts from zero when the server answers 416 for a stale .part');
    it.todo('deletes the .part and reports checksum-mismatch when SHA-256 differs');
    it.todo('renames .part to the final name only after size + SHA-256 verification');
    it.todo('pauses by aborting the request and keeps the .part');
    it.todo('cancels by aborting and deleting the .part, returning to idle');
    it.todo('retries transient failures with exponential backoff and a bounded attempt count');
    it.todo('reports disk-full when a write fails with ENOSPC and leaves no final file');
    it.todo('reports http-404 for a missing artifact and never creates a final file');
    it.todo('refuses a model whose minEngine is newer than the pinned runtime');
    it.todo('runs one download at a time and keeps the rest queued');
    it.todo('verifies an already-installed GGUF without any HTTP request');
});
