import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const snapshotPath = path.join(repoRoot, 'shared', 'handy-speech-catalog.json');
const scriptPath = path.join(repoRoot, 'scripts', 'sync_handy_speech_catalog.mjs');
const referenceRoot = process.env.HANDY_REF || '/workspace/handy-ref';

const snapshot = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));

test('snapshot has exactly 29 curated ASR models', () => {
    assert.equal(snapshot.models.length, 29);
    assert.equal(new Set(snapshot.models.map((model) => model.id)).size, 29);
    for (const model of snapshot.models) {
        assert.equal(model.role, 'asr');
        assert.equal(model.curated, true);
        assert.equal(model.file.quant, model.quant);
        assert.match(model.file.sha256, /^[0-9a-f]{64}$/);
        assert.equal(
            model.file.url,
            `https://huggingface.co/${model.repository}/resolve/${model.revision}/${model.file.filename}`,
        );
    }
});

test('recommended and more accurate ids carry their real byte sizes', () => {
    const parakeet = snapshot.models.find((model) => model.id === 'parakeet-unified-en-0.6b');
    assert.ok(parakeet);
    assert.equal(parakeet.file.size, 731357568);

    const qwen = snapshot.models.find((model) => model.id === 'Qwen3-ASR-1.7B');
    assert.ok(qwen);
    assert.equal(qwen.file.size, 2185030624);
    assert.equal(Math.round((qwen.file.size / 1024 ** 3) * 10) / 10, 2);
});

test('provenance pins Handy and @handy-computer/models@0.2.3 under MIT', () => {
    assert.equal(snapshot.source.handy.repository, 'https://github.com/cjpais/Handy');
    assert.match(snapshot.source.handy.commit, /^[0-9a-f]{40}$/);
    assert.equal(snapshot.source.handy.license, 'MIT');
    assert.equal(snapshot.source.handy.copyright, 'Copyright (c) 2025 CJ Pais');
    assert.equal(snapshot.source.package.name, '@handy-computer/models');
    assert.equal(snapshot.source.package.version, '0.2.3');
    assert.equal(snapshot.source.package.license, 'MIT');
});

test('--check reproduces the snapshot byte-for-byte', (t) => {
    if (!fs.existsSync(path.join(referenceRoot, 'COMMIT'))) {
        t.skip(`Handy reference not present at ${referenceRoot}`);
        return;
    }
    const result = spawnSync(process.execPath, [scriptPath, '--check'], {
        cwd: repoRoot,
        encoding: 'utf8',
        env: { ...process.env, HANDY_REF: referenceRoot },
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});
