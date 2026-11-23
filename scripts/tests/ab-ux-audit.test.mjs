import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const websiteDir = path.join(root, 'website');
const docsDir = path.join(websiteDir, 'docs');
const uiSrcDir = path.join(root, 'ui', 'src');

function stripHtmlTags(raw) {
    let out = '';
    let inTag = false;
    for (const ch of raw) {
        if (ch === '<') { inTag = true; continue; }
        if (ch === '>') { inTag = false; continue; }
        if (!inTag) out += ch;
    }
    return out.replace(/\s+/g, ' ').trim();
}

function paragraphStats(html) {
    const lengths = [...html.matchAll(/<p(?:\s[^>]*)?>(.*?)<\/p>/gs)]
        .map((m) => stripHtmlTags(m[1]).length)
        .filter((n) => n > 0);
    return {
        max: lengths.length ? Math.max(...lengths) : 0,
        over650: lengths.filter((n) => n > 650).length,
        over380: lengths.filter((n) => n > 380).length,
    };
}

function adjacentTintCollisions(html) {
    const classes = [...html.matchAll(/<section\b([^>]*)>/gi)]
        .map((m) => {
            const cls = m[1].match(/\bclass="([^"]*)"/i);
            return cls ? cls[1].split(/\s+/) : [];
        });
    let collisions = 0;
    for (let i = 1; i < classes.length; i++) {
        const prevIsTint = classes[i - 1].includes('section') && classes[i - 1].includes('tint');
        const curIsTint = classes[i].includes('section') && classes[i].includes('tint');
        if (prevIsTint && curIsTint) collisions += 1;
    }
    return collisions;
}

function walkFiles(dir, exts) {
    const out = [];
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walkFiles(full, exts));
        else if (exts.some((ext) => entry.name.endsWith(ext))) out.push(full);
    }
    return out;
}

function gitShow(ref, relPath) {
    try {
        return execFileSync('git', ['-C', root, 'show', `${ref}:${relPath}`], {
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'ignore'],
        });
    } catch {
        return null;
    }
}

function gitListTree(ref, relDir, suffix) {
    try {
        return execFileSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', ref, relDir], {
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'ignore'],
        })
            .split('\n')
            .map((s) => s.trim())
            .filter((s) => s && s.endsWith(suffix));
    } catch {
        return [];
    }
}

test('Variant B enforces scannable prose, brand palette tokens, zero glassmorphic chrome, and zero analytics', () => {
    // 1. Documentation portal: all 30 files stay <= 650 chars per <p>, no broken bold/em wildcards, solid header
    const docFiles = readdirSync(docsDir).filter((f) => f.endsWith('.html'));
    assert.equal(docFiles.length, 30);
    let maxDocPara = 0;
    for (const file of docFiles) {
        const html = readFileSync(path.join(docsDir, file), 'utf8');
        const stats = paragraphStats(html);
        if (stats.max > maxDocPara) maxDocPara = stats.max;
        assert.equal(stats.over650, 0, `${file} has paragraph >650 chars (max=${stats.max})`);
        assert.ok(!html.includes('<strong>win.\\</strong>'), `${file} leaked broken wildcard emphasis`);
        assert.ok(!/<(?:script|link|img|iframe)\b[^>]*(?:src|href)=["']https?:\/\/[^"']*(?:fonts\.googleapis|googletagmanager|google-analytics|mixpanel|amplitude|segment\.com)/i.test(html), `${file} loads external CDN or analytics resource`);
    }
    assert.ok(maxDocPara <= 650, `Expected max docs paragraph <= 650, got ${maxDocPara}`);

    const docsCss = readFileSync(path.join(docsDir, 'docs.css'), 'utf8');
    const docsHeaderRule = docsCss.match(/\.docs-header\s*\{[^}]+\}/s)?.[0] ?? '';
    assert.ok(!/backdrop-filter\s*:\s*blur/i.test(docsHeaderRule), 'docs-header must not use backdrop-filter glassmorphism');

    // 2. Website CSS & brand palette: zero Stripe indigo/purple & zero backdrop-filter glassmorphism
    const stylesCss = readFileSync(path.join(websiteDir, 'styles.css'), 'utf8');
    assert.ok(!/122,\s*115,\s*255|#635bff|#7a73ff|#8b5cf6|#a855f7/i.test(stylesCss), 'website/styles.css must use Quenderin teal/copper, not Stripe purple');
    assert.ok(!/backdrop-filter\s*:\s*blur/i.test(stylesCss), 'website/styles.css must not use backdrop-filter blur');

    const detailCss = readFileSync(path.join(websiteDir, 'detail-page.css'), 'utf8');
    assert.match(detailCss, /\.detail-page\s+\.btn\s*\{[^}]*border-radius:\s*var\(--r-md\)/);

    // 3. tell-me-more.html: alternating section rhythm + Nov 22 refresh + translated catalog roles
    const tmm = readFileSync(path.join(websiteDir, 'tell-me-more.html'), 'utf8');
    assert.equal(adjacentTintCollisions(tmm), 0, 'tell-me-more.html must alternate .section and .section.tint cleanly');
    assert.ok(tmm.includes('22 November 2026'), 'tell-me-more.html latest-update must reflect 22 November 2026');
    assert.ok(!tmm.includes('9 November update</a>'), 'tell-me-more.html caveat should point to 22 November update');
    assert.ok(tmm.includes('data-i18n="catalog.role.experimental_text"'));
    assert.ok(tmm.includes('data-i18n="catalog.role.experimental_prism"'));

    // 4. download.html: header/theme/i18n parity + structured cards + <=380-char paragraphs
    const dl = readFileSync(path.join(websiteDir, 'download.html'), 'utf8');
    assert.ok(dl.includes('class="site-header"'), 'download.html must share site-header');
    assert.ok(dl.includes('class="lang-select"'), 'download.html must expose language switcher');
    assert.ok(dl.includes('class="theme-toggle"'), 'download.html must expose theme toggle');
    assert.ok(dl.includes('class="site-footer"'), 'download.html must include full site-footer');
    assert.ok(dl.includes('i18n.js'), 'download.html must load i18n.js');
    assert.ok(dl.includes('data-copy-target="dl-cli-cmd"'), 'download.html CLI block must include copy button');
    const dlStats = paragraphStats(dl);
    assert.equal(dlStats.over380, 0, `download.html should avoid >380-char text walls (max=${dlStats.max})`);

    // 5. Desktop Electron UI (ui/src + ui/tailwind.config.js): zero purple-* & zero backdrop-blur-*
    const tailwindCfg = readFileSync(path.join(root, 'ui', 'tailwind.config.js'), 'utf8');
    assert.ok(tailwindCfg.includes('qteal:') && tailwindCfg.includes('qcopper:'), 'ui/tailwind.config.js must define Quenderin brand tokens');
    const uiFiles = walkFiles(uiSrcDir, ['.ts', '.tsx', '.css']);
    assert.ok(uiFiles.length >= 20);
    for (const file of uiFiles) {
        const text = readFileSync(file, 'utf8');
        const rel = path.relative(root, file);
        assert.ok(!/\b(?:bg|text|border|ring|outline|accent|selection:bg)-purple-\d+/.test(text), `${rel} still contains Tailwind purple-*`);
        assert.ok(!/\bbackdrop-blur(?:-sm|-md|-lg|-xl|-2xl)?\b/.test(text), `${rel} still contains backdrop-blur glassmorphism`);
    }
});

test('A/B scorecard compares pre-UX baseline 665bd94 (Variant A) vs current UX overhaul (Variant B) when git history is present', (t) => {
    const baselineRef = '665bd94';
    let hasBaseline = false;
    try {
        execFileSync('git', ['-C', root, 'cat-file', '-e', `${baselineRef}^{commit}`], { stdio: 'ignore' });
        hasBaseline = true;
    } catch {
        hasBaseline = false;
    }
    if (!hasBaseline) {
        t.skip(`baseline commit ${baselineRef} unavailable in shallow CI checkout`);
        return;
    }

    const baseDocs = gitListTree(baselineRef, 'website/docs', '.html');
    const baseMaxDocPara = baseDocs.reduce((acc, rel) => {
        const html = gitShow(baselineRef, rel);
        return html ? Math.max(acc, paragraphStats(html).max) : acc;
    }, 0);

    const curMaxDocPara = readdirSync(docsDir)
        .filter((f) => f.endsWith('.html'))
        .reduce((acc, f) => Math.max(acc, paragraphStats(readFileSync(path.join(docsDir, f), 'utf8')).max), 0);

    const baseDl = gitShow(baselineRef, 'website/download.html') ?? '';
    const curDl = readFileSync(path.join(websiteDir, 'download.html'), 'utf8');
    const baseDlMax = paragraphStats(baseDl).max;
    const curDlMax = paragraphStats(curDl).max;
    const baseDlI18n = (baseDl.match(/data-i18n/g) ?? []).length;
    const curDlI18n = (curDl.match(/data-i18n/g) ?? []).length;

    const baseTmm = gitShow(baselineRef, 'website/tell-me-more.html') ?? '';
    const curTmm = readFileSync(path.join(websiteDir, 'tell-me-more.html'), 'utf8');
    const baseTints = adjacentTintCollisions(baseTmm);
    const curTints = adjacentTintCollisions(curTmm);

    const uiFilesRel = walkFiles(uiSrcDir, ['.ts', '.tsx', '.css']).map((p) => path.relative(root, p));
    const countPattern = (files, useGit, regex) => files.reduce((acc, rel) => {
        const text = useGit ? gitShow(baselineRef, rel) : readFileSync(path.join(root, rel), 'utf8');
        if (!text) return acc;
        return acc + (text.match(regex) ?? []).length;
    }, 0);
    const purpleRe = /\b(?:bg|text|border|ring|outline|accent|selection:bg)-purple-\d+/g;
    const blurRe = /\bbackdrop-blur(?:-sm|-md|-lg|-xl|-2xl)?\b/g;

    const basePurple = countPattern(uiFilesRel, true, purpleRe);
    const curPurple = countPattern(uiFilesRel, false, purpleRe);
    const baseBlur = countPattern(uiFilesRel, true, blurRe);
    const curBlur = countPattern(uiFilesRel, false, blurRe);

    console.log(`\n--- A/B Engineering & UX Scorecard (Variant A: ${baselineRef} -> Variant B: HEAD/working tree) ---`);
    console.log(`Docs max <p> length      : A=${baseMaxDocPara} chars -> B=${curMaxDocPara} chars`);
    console.log(`download.html max <p>    : A=${baseDlMax} chars -> B=${curDlMax} chars`);
    console.log(`download.html i18n attrs : A=${baseDlI18n} -> B=${curDlI18n}`);
    console.log(`tell-me-more .tint clash : A=${baseTints} -> B=${curTints}`);
    console.log(`Desktop UI purple-* uses : A=${basePurple} -> B=${curPurple}`);
    console.log(`Desktop UI backdrop-blur : A=${baseBlur} -> B=${curBlur}`);

    assert.ok(curMaxDocPara < baseMaxDocPara && curMaxDocPara <= 650);
    assert.ok(curDlMax < baseDlMax && curDlMax <= 380);
    assert.ok(curDlI18n > baseDlI18n && curDlI18n >= 35);
    assert.ok(curTints < baseTints && curTints === 0);
    assert.ok(curPurple < basePurple && curPurple === 0);
    assert.ok(curBlur < baseBlur && curBlur === 0);
});
