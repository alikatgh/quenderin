import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const websiteDir = path.join(root, 'website');
const docsDir = path.join(websiteDir, 'docs');

test('self-hosted font assets exist and use WOFF2 compression', () => {
    for (const file of ['dinish-variable.woff2', 'chunkfive-regular.woff2', 'lucide.woff2']) {
        const p = path.join(websiteDir, 'fonts', file);
        assert.ok(existsSync(p), `Missing font file: ${p}`);
        const buf = readFileSync(p);
        assert.equal(buf.subarray(0, 4).toString('ascii'), 'wOF2', `${file} is not valid WOFF2`);
    }
    const styles = readFileSync(path.join(websiteDir, 'styles.css'), 'utf8');
    assert.match(styles, /fonts\/dinish-variable\.woff2/);
    assert.match(styles, /fonts\/chunkfive-regular\.woff2/);
    const lucideCss = readFileSync(path.join(websiteDir, 'lucide-icons.css'), 'utf8');
    assert.match(lucideCss, /fonts\/lucide\.woff2/);
    assert.ok(!lucideCss.includes('[class*=" icon-"]'), 'Lucide CSS must not hijack .icon-* selectors');
});

test('all 30 documentation HTML files and valid search indexes exist', () => {
    const htmlFiles = readdirSync(docsDir).filter((f) => f.endsWith('.html'));
    assert.equal(htmlFiles.length, 30);

    const indexJson = JSON.parse(readFileSync(path.join(docsDir, 'search-index.json'), 'utf8'));
    assert.equal(indexJson.length, 30);

    const ctx = { window: {} };
    vm.runInNewContext(readFileSync(path.join(docsDir, 'search-index.js'), 'utf8'), ctx);
    assert.equal(ctx.window.QUENDERIN_DOCS_INDEX.length, 30);

    for (const entry of indexJson) {
        assert.ok(existsSync(path.join(docsDir, `${entry.slug}.html`)));
        assert.ok(Array.isArray(entry.sources) && entry.sources.length >= 1);
    }
});

test('marketing and documentation pages link lucide-icons.css and expose Docs navigation without external CDNs', () => {
    const topPages = readdirSync(websiteDir).filter((f) => f.endsWith('.html'));
    for (const file of topPages) {
        const html = readFileSync(path.join(websiteDir, file), 'utf8');
        assert.ok(html.includes('lucide-icons.css'), `${file} must load lucide-icons.css`);
        assert.ok(html.includes('docs/'), `${file} must link to docs/`);
        assert.ok(!/fonts\.googleapis|cdn\.jsdelivr|unpkg\.com|cdnjs\.cloudflare/i.test(html), `${file} must stay 100% self-hosted`);
    }

    for (const file of readdirSync(docsDir).filter((f) => f.endsWith('.html'))) {
        const html = readFileSync(path.join(docsDir, file), 'utf8');
        assert.ok(html.includes('../styles.css'), `${file} missing ../styles.css`);
        assert.ok(html.includes('../lucide-icons.css'), `${file} missing ../lucide-icons.css`);
        assert.ok(html.includes('docs.css'), `${file} missing docs.css`);
        assert.ok(!html.includes('/Users/'), `${file} leaked local checkout path`);
    }

    const stripTags = (s) => {
        let out = '';
        let inTag = false;
        for (const ch of s) {
            if (ch === '<') { inTag = true; continue; }
            if (ch === '>') { inTag = false; continue; }
            if (!inTag) out += ch;
        }
        return out;
    };
    for (const file of readdirSync(docsDir).filter((f) => f.endsWith('.html'))) {
        const html = readFileSync(path.join(docsDir, file), 'utf8');
        const longParas = [...html.matchAll(/<p(?:\s[^>]*)?>(.*?)<\/p>/gs)]
            .map((m) => stripTags(m[1]))
            .filter((plain) => plain.length > 650);
        assert.deepEqual(longParas, [], `${file} should chunk oversized >650-char narrative paragraphs`);
    }
    const cliDoc = readFileSync(path.join(docsDir, 'cli-and-agent.html'), 'utf8');
    assert.ok(cliDoc.includes('class="docs-entry"'), 'cli-and-agent.html should group bold-lead logs into .docs-entry cards');
});

test('all referenced section-illustrations SVG symbols exist in sprite', () => {
    const sprite = readFileSync(path.join(websiteDir, 'assets', 'blog', 'section-illustrations.svg'), 'utf8');
    const defined = new Set([...sprite.matchAll(/<symbol\s+id="([^"]+)"/g)].map((m) => m[1]));
    assert.ok(defined.size > 0, 'section-illustrations.svg must define symbols');

    for (const file of readdirSync(websiteDir).filter((f) => f.endsWith('.html'))) {
        const html = readFileSync(path.join(websiteDir, file), 'utf8');
        for (const match of html.matchAll(/section-illustrations\.svg#([a-zA-Z0-9_-]+)/g)) {
            assert.ok(defined.has(match[1]), `${file} references missing SVG symbol #${match[1]}`);
        }
    }
});

test('all 12 i18n language files have 100% key parity and cover all HTML data-i18n attributes', () => {
    const i18nDir = path.join(websiteDir, 'i18n');
    const en = JSON.parse(readFileSync(path.join(i18nDir, 'en.json'), 'utf8'));
    const enKeys = Object.keys(en);
    const langs = readdirSync(i18nDir).filter((f) => f.endsWith('.json')).sort();
    assert.equal(langs.length, 12, 'Expected 12 i18n language JSON files');

    const dicts = new Map();
    for (const file of langs) {
        const dict = JSON.parse(readFileSync(path.join(i18nDir, file), 'utf8'));
        const missing = enKeys.filter((k) => !(k in dict) || typeof dict[k] !== 'string' || dict[k].trim() === '');
        const extra = Object.keys(dict).filter((k) => !(k in en));
        assert.deepEqual(missing, [], `${file} missing keys: ${missing.join(', ')}`);
        assert.deepEqual(extra, [], `${file} has unexpected extra keys: ${extra.join(', ')}`);
        dicts.set(file, dict);
    }

    for (const htmlFile of readdirSync(websiteDir).filter((f) => f.endsWith('.html'))) {
        const html = readFileSync(path.join(websiteDir, htmlFile), 'utf8');
        for (const match of html.matchAll(/data-i18n(?:-(?:html|placeholder))?="([^"]+)"/g)) {
            const key = match[1];
            assert.ok(key in en, `${htmlFile} uses unknown i18n key: ${key}`);
            for (const [langFile, dict] of dicts) {
                assert.ok(key in dict, `${langFile} missing key ${key} used by ${htmlFile}`);
            }
        }
    }
});
