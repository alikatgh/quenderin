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

    // 3. tell-me-more.html: alternating section rhythm + Nov 27 refresh + translated catalog roles
    const tmm = readFileSync(path.join(websiteDir, 'tell-me-more.html'), 'utf8');
    assert.equal(adjacentTintCollisions(tmm), 0, 'tell-me-more.html must alternate .section and .section.tint cleanly');
    assert.ok(tmm.includes('27 November 2026'), 'tell-me-more.html latest-update must reflect 27 November 2026');
    assert.ok(!tmm.includes('>9 November update</a>'), 'tell-me-more.html must omit the stale 9 November update link');
    const privacyCaveat = tmm.match(/<p\b[^>]*\bdata-i18n-html="tmm\.priv\.caveat"[^>]*>(.*?)<\/p>/s)?.[1] ?? '';
    assert.ok(privacyCaveat.includes('<a href="#latest-update">27 November update</a>'), 'tell-me-more.html privacy caveat must link to the 27 November update');
    assert.ok(tmm.includes('data-i18n="catalog.role.experimental_text"'));
    assert.ok(tmm.includes('data-i18n="catalog.role.experimental_prism"'));
    for (let c = 1; c <= 6; c += 1) {
        assert.ok(tmm.includes(`data-i18n="tmm.oct.c${c}.h3"`), `tell-me-more.html missing tmm.oct.c${c}.h3`);
    }
    assert.ok(tmm.includes('data-i18n="tmm.oct.notes.sum"'), 'tell-me-more.html missing tmm.oct.notes.sum');

    // 4. All top-level marketing/legal/blog HTML pages: <=650-char <p>, theme.js, theme-toggle, unified styles cache-buster, zero analytics
    const topPages = readdirSync(websiteDir).filter((f) => f.endsWith('.html'));
    assert.equal(topPages.length, 38); // Includes the new 0.6.3 blog post.
    for (const file of topPages) {
        const html = readFileSync(path.join(websiteDir, file), 'utf8');
        const stats = paragraphStats(html);
        assert.equal(stats.over650, 0, `${file} has paragraph >650 chars (max=${stats.max})`);
        assert.ok(html.includes('<script src="theme.js"></script>'), `${file} must load shared theme.js`);
        assert.ok(html.includes('class="theme-toggle"'), `${file} must expose theme-toggle button`);
        assert.ok(html.includes('href="styles.css?v=20261124-craft"'), `${file} must load unified styles.css?v=20261124-craft`);
        assert.ok(!/<(?:script|link|img|iframe)\b[^>]*(?:src|href)=["']https?:\/\/[^"']*(?:fonts\.googleapis|googletagmanager|google-analytics|mixpanel|amplitude|segment\.com)/i.test(html), `${file} loads external CDN or analytics resource`);
    }

    // 4b. Homepage localization & interactive curated catalog explorer parity
    const indexHtml = readFileSync(path.join(websiteDir, 'index.html'), 'utf8');
    assert.ok(indexHtml.includes('data-i18n="simple.update.latest.title"'), 'index.html latest update headline must be localized');
    assert.ok(indexHtml.includes('href="blog" data-language-link data-i18n="nav.blog"'), 'index.html footer blog link must persist language and localize');
    for (const file of ['models.html', 'tell-me-more.html']) {
        const page = readFileSync(path.join(websiteDir, file), 'utf8');
        assert.ok(page.includes('data-catalog-explorer'), `${file} must include interactive curated catalog explorer`);
        assert.ok(page.includes('data-catalog-search'), `${file} must include catalog search input`);
        assert.ok(page.includes('data-catalog-tier="phone"'), `${file} must include hardware tier filters`);
    }

    // 5. Core interactive marketing & guide pages: shared header/footer/i18n/theme parity
    for (const file of [
        'download.html',
        'faq.html',
        'features.html',
        'help.html',
        'how-it-works.html',
        'models.html',
        'reality.html',
        'roadmap.html',
        'tell-me-more.html',
        'why-local-agent.html',
    ]) {
        const page = readFileSync(path.join(websiteDir, file), 'utf8');
        assert.ok(page.includes('class="site-header"'), `${file} must share site-header`);
        assert.ok(page.includes('class="lang-select"'), `${file} must expose language switcher`);
        assert.ok(page.includes('class="theme-toggle"'), `${file} must expose theme toggle`);
        assert.ok(page.includes('class="site-footer"'), `${file} must include full site-footer`);
        assert.ok(page.includes('i18n.js'), `${file} must load i18n.js`);
    }
    const dl = readFileSync(path.join(websiteDir, 'download.html'), 'utf8');
    assert.ok(dl.includes('data-copy-target="dl-cli-cmd"'), 'download.html CLI block must include copy button');
    const dlStats = paragraphStats(dl);
    assert.equal(dlStats.over380, 0, `download.html should avoid >380-char text walls (max=${dlStats.max})`);

    // 6. Desktop Electron UI (ui/src + ui/tailwind.config.js): zero purple-* & zero backdrop-blur-*
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

function parseHexToken(block, varName) {
    const match = block.match(new RegExp(`${varName}\\s*:\\s*(#[0-9a-fA-F]{3,8}|var\\(--[a-zA-Z0-9-]+\\))`));
    assert.ok(match, `Missing CSS token ${varName}`);
    return match[1];
}

function resolveCssHex(block, rootBlock, varName, visited = new Set()) {
    assert.ok(!visited.has(varName), `Cyclic CSS var reference: ${varName}`);
    visited.add(varName);
    const raw = block.includes(`${varName}:`) ? parseHexToken(block, varName) : parseHexToken(rootBlock, varName);
    if (raw.startsWith('#')) return raw.length === 4 ? `#${raw[1]}${raw[1]}${raw[2]}${raw[2]}${raw[3]}${raw[3]}` : raw;
    const ref = raw.match(/^var\((--[a-zA-Z0-9-]+)\)$/);
    assert.ok(ref, `Cannot resolve non-hex token ${varName}=${raw}`);
    return resolveCssHex(block, rootBlock, ref[1], visited);
}

function relativeLuminance(hex) {
    const clean = hex.replace('#', '');
    const n = Number.parseInt(clean.slice(0, 6), 16);
    const channels = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => {
        const s = c / 255;
        return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function contrastRatio(fgHex, bgHex) {
    const l1 = relativeLuminance(fgHex);
    const l2 = relativeLuminance(bgHex);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

test('WCAG 2.1 AA (>= 4.5:1) holds across styles.css, detail-page.css, docs.css, and tailwind.config.js', () => {
    const stylesCss = readFileSync(path.join(websiteDir, 'styles.css'), 'utf8');
    const detailCss = readFileSync(path.join(websiteDir, 'detail-page.css'), 'utf8');
    const docsCss = readFileSync(path.join(docsDir, 'docs.css'), 'utf8');
    const tailwindCfg = readFileSync(path.join(root, 'ui', 'tailwind.config.js'), 'utf8');

    const rootBlock = stylesCss.match(/:root\s*\{([^}]+)\}/s)?.[1] ?? '';
    const darkSectionBlock = stylesCss.match(/\n\[data-theme="dark"\]\s*\{([^}]+)\}/s)?.[1] ?? '';
    const darkModeBlock = stylesCss.match(/html\[data-theme-mode="dark"\]\s*\{([^}]+)\}/s)?.[1] ?? '';
    const detailLightBlock = detailCss.match(/\.detail-page\s*\{([^}]+)\}/s)?.[1] ?? '';
    const detailDarkBlock = detailCss.match(/\.detail-page\s+\[data-theme="dark"\]\s*\{([^}]+)\}/s)?.[1] ?? '';
    const docsLightBlock = docsCss.match(/\.docs-page\s*\{([^}]+)\}/s)?.[1] ?? '';
    const docsDarkBlock = docsCss.match(/html\[data-theme-mode="dark"\]\s*\.docs-page\s*\{([^}]+)\}/s)?.[1] ?? '';

    assert.ok(rootBlock && darkSectionBlock && darkModeBlock, 'Missing styles.css token blocks');
    assert.ok(detailLightBlock && detailDarkBlock, 'Missing detail-page.css token blocks');
    assert.ok(docsLightBlock && docsDarkBlock, 'Missing docs.css token blocks');

    const checks = [
        ['light body on canvas', resolveCssHex(rootBlock, rootBlock, '--text'), resolveCssHex(rootBlock, rootBlock, '--canvas')],
        ['light body on tint', resolveCssHex(rootBlock, rootBlock, '--text'), resolveCssHex(rootBlock, rootBlock, '--surface-tint')],
        ['light secondary on tint', resolveCssHex(rootBlock, rootBlock, '--text-secondary'), resolveCssHex(rootBlock, rootBlock, '--surface-tint')],
        ['light muted on canvas', resolveCssHex(rootBlock, rootBlock, '--text-muted'), resolveCssHex(rootBlock, rootBlock, '--canvas')],
        ['light muted on tint', resolveCssHex(rootBlock, rootBlock, '--text-muted'), resolveCssHex(rootBlock, rootBlock, '--surface-tint')],
        ['light brand on canvas', resolveCssHex(rootBlock, rootBlock, '--brand'), resolveCssHex(rootBlock, rootBlock, '--canvas')],
        ['light brand on tint', resolveCssHex(rootBlock, rootBlock, '--brand'), resolveCssHex(rootBlock, rootBlock, '--surface-tint')],
        ['primary CTA text on copper-cta', resolveCssHex(rootBlock, rootBlock, '--on-brand'), resolveCssHex(rootBlock, rootBlock, '--copper-cta')],
        ['primary CTA text on copper-cta-hover', resolveCssHex(rootBlock, rootBlock, '--on-brand'), resolveCssHex(rootBlock, rootBlock, '--copper-cta-hover')],
        ['header text on header-surface', resolveCssHex(rootBlock, rootBlock, '--header-text'), resolveCssHex(rootBlock, rootBlock, '--header-surface')],
        ['header secondary on header-surface', resolveCssHex(rootBlock, rootBlock, '--header-secondary'), resolveCssHex(rootBlock, rootBlock, '--header-surface')],
        ['header accent on header-surface', resolveCssHex(rootBlock, rootBlock, '--header-accent'), resolveCssHex(rootBlock, rootBlock, '--header-surface')],
        ['dark section brand on ink-900', resolveCssHex(darkSectionBlock, rootBlock, '--brand'), resolveCssHex(rootBlock, rootBlock, '--ink-900')],
        ['dark section brand on ink-800', resolveCssHex(darkSectionBlock, rootBlock, '--brand'), resolveCssHex(rootBlock, rootBlock, '--ink-800')],
        ['dark section muted on ink-800', resolveCssHex(darkSectionBlock, rootBlock, '--text-muted'), resolveCssHex(rootBlock, rootBlock, '--ink-800')],
        ['dark mode text on surface', resolveCssHex(darkModeBlock, rootBlock, '--text'), resolveCssHex(darkModeBlock, rootBlock, '--surface')],
        ['dark mode muted on tint', resolveCssHex(darkModeBlock, rootBlock, '--text-muted'), resolveCssHex(darkModeBlock, rootBlock, '--surface-tint')],
        ['dark mode brand on tint', resolveCssHex(darkModeBlock, rootBlock, '--brand'), resolveCssHex(darkModeBlock, rootBlock, '--surface-tint')],
        ['detail light brand on tint', parseHexToken(detailLightBlock, '--brand'), parseHexToken(detailLightBlock, '--surface-tint')],
        ['detail light muted on tint', parseHexToken(detailLightBlock, '--text-muted'), parseHexToken(detailLightBlock, '--surface-tint')],
        ['detail dark brand on surface', parseHexToken(detailDarkBlock, '--brand'), parseHexToken(detailDarkBlock, '--surface')],
        ['detail dark muted on tint', parseHexToken(detailDarkBlock, '--text-muted'), parseHexToken(detailDarkBlock, '--surface-tint')],
        ['docs light link on paper tint', parseHexToken(docsLightBlock, '--doc-link'), resolveCssHex(rootBlock, rootBlock, '--surface-tint')],
        ['docs light tip label on paper tint', parseHexToken(docsLightBlock, '--doc-tip-border'), resolveCssHex(rootBlock, rootBlock, '--surface-tint')],
        ['docs dark link on ink-900', parseHexToken(docsDarkBlock, '--doc-link'), resolveCssHex(rootBlock, rootBlock, '--ink-900')],
    ];

    const qteal500 = tailwindCfg.match(/qteal:\s*\{[^}]*500:\s*'(#[0-9a-fA-F]{6})'/s)?.[1];
    const qteal600 = tailwindCfg.match(/qteal:\s*\{[^}]*600:\s*'(#[0-9a-fA-F]{6})'/s)?.[1];
    const qcopper600 = tailwindCfg.match(/qcopper:\s*\{[^}]*600:\s*'(#[0-9a-fA-F]{6})'/s)?.[1];
    assert.ok(qteal500 && qteal600 && qcopper600, 'Missing Tailwind brand tokens');
    checks.push(['tailwind qteal-500 on white', qteal500, '#ffffff']);
    checks.push(['tailwind white on qteal-600', '#ffffff', qteal600]);
    checks.push(['tailwind white on qcopper-600', '#ffffff', qcopper600]);

    for (const [label, fg, bg] of checks) {
        const ratio = contrastRatio(fg, bg);
        assert.ok(ratio >= 4.5, `${label} (${fg} on ${bg}) contrast ${ratio.toFixed(2)}:1 < 4.5:1`);
    }
});
