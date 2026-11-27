import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';

const repoRoot = process.cwd();
const snapshotPath = path.join(repoRoot, 'shared', 'handy-speech-catalog.json');
const scriptPath = path.join(repoRoot, 'scripts', 'sync_handy_speech_catalog.mjs');
const referenceRoot = process.env.HANDY_REF || '/workspace/handy-ref';

interface CatalogFile {
    quant: string;
    filename: string;
    size: number;
    sha256: string;
    url: string;
}

interface CatalogModel {
    id: string;
    name: string;
    repository: string;
    revision: string;
    license: string;
    role: string;
    curated: boolean;
    minEngine: string;
    languages: string[];
    capabilities: { streaming: boolean; translate: boolean; languageDetection: boolean; timestamps: boolean };
    file: CatalogFile;
}

interface Snapshot {
    schema: number;
    source: {
        handy: { repository: string; commit: string; license: string; copyright: string };
        package: { name: string; version: string; license: string };
    };
    transcribeCpp: string;
    methodology: Record<string, number>;
    benchmarks: Record<string, unknown>;
    models: CatalogModel[];
    results: Record<string, { accuracy: Record<string, { error: number }>; performance: Record<string, number> }>;
}

const snapshot = JSON.parse(fs.readFileSync(snapshotPath, 'utf8')) as Snapshot;
const byId = new Map(snapshot.models.map((model) => [model.id, model]));

function sha256Pattern(value: string): boolean {
    return /^[0-9a-f]{64}$/.test(value);
}

describe('Handy speech catalog snapshot', () => {
    it('contains exactly the 29 curated ASR models from Handy', () => {
        expect(snapshot.models).toHaveLength(29);
        expect(new Set(snapshot.models.map((model) => model.id)).size).toBe(29);
        for (const model of snapshot.models) {
            expect(model.role).toBe('asr');
            expect(model.curated).toBe(true);
            expect(model.languages.length).toBeGreaterThan(0);
            expect(model.minEngine).toMatch(/^\d+\.\d+\.\d+$/);
            expect(model.file.quant).toBe(model.quant);
            expect(sha256Pattern(model.file.sha256)).toBe(true);
            expect(model.file.size).toBeGreaterThan(0);
        }
    });

    it('pins the recommended Parakeet Unified English 0.6B at 731357568 bytes', () => {
        const model = byId.get('parakeet-unified-en-0.6b');
        expect(model).toBeDefined();
        if (!model) return;
        expect(model.name).toBe('Parakeet Unified English 0.6B');
        expect(model.file.quant).toBe('Q8_0');
        expect(model.file.filename).toBe('parakeet-unified-en-0.6b-Q8_0.gguf');
        expect(model.file.size).toBe(731357568);
        expect(model.file.sha256).toBe('4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795');
        expect(model.file.url).toBe(
            'https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/' +
            `${model.revision}/${model.file.filename}`,
        );
    });

    it('keeps the more accurate Qwen3-ASR 1.7B with its ~2.0 GB Q8_0 file', () => {
        const model = byId.get('Qwen3-ASR-1.7B');
        expect(model).toBeDefined();
        if (!model) return;
        expect(model.file.filename).toBe('Qwen3-ASR-1.7B-Q8_0.gguf');
        expect(model.file.size).toBe(2185030624);
        const gib = model.file.size / 1024 ** 3;
        expect(Math.round(gib * 10) / 10).toBe(2.0);
    });

    it('carries real results, methodology and benchmarks for every model', () => {
        expect(Object.keys(snapshot.results)).toHaveLength(29);
        for (const model of snapshot.models) {
            const result = snapshot.results[model.id];
            expect(result, `missing results for ${model.id}`).toBeDefined();
            expect(typeof result.performance.accelerated).toBe('number');
            if (model.languages.includes('en')) {
                expect(typeof result.accuracy.en?.error, `missing EN result for ${model.id}`).toBe('number');
            }
        }
        expect(snapshot.transcribeCpp).toBe('0.4.0');
        expect(snapshot.methodology.dictationSeconds).toBe(30);
        expect(snapshot.methodology.maxLanguageErrorPercent).toBe(20);
        expect(snapshot.benchmarks).toBeTypeOf('object');
    });

    it('records Handy and @handy-computer/models provenance with MIT attribution', () => {
        expect(snapshot.source.handy.repository).toBe('https://github.com/cjpais/Handy');
        expect(snapshot.source.handy.commit).toMatch(/^[0-9a-f]{40}$/);
        expect(snapshot.source.handy.license).toBe('MIT');
        expect(snapshot.source.handy.copyright).toBe('Copyright (c) 2025 CJ Pais');
        expect(snapshot.source.package.name).toBe('@handy-computer/models');
        expect(snapshot.source.package.version).toBe('0.2.3');
        expect(snapshot.source.package.license).toBe('MIT');
    });

    it('builds every download URL from the pinned repository, revision and filename', () => {
        for (const model of snapshot.models) {
            expect(model.file.url).toBe(
                `https://huggingface.co/${model.repository}/resolve/${model.revision}/${model.file.filename}`,
            );
        }
    });

    it.runIf(fs.existsSync(path.join(referenceRoot, 'COMMIT')))(
        'is byte-identical to a fresh generation from the reference (--check)',
        () => {
            const result = spawnSync(process.execPath, [scriptPath, '--check'], {
                cwd: repoRoot,
                encoding: 'utf8',
                env: { ...process.env, HANDY_REF: referenceRoot },
                timeout: 30_000,
            });
            expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
        },
    );
});
