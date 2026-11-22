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
});
