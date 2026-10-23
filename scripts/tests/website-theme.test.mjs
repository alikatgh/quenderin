import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../website/theme.js', import.meta.url), 'utf8');
// Deliberately distinct fixture colors verify that the resolver respects the
// page's declared appearance colors instead of substituting hard-coded values.
const chrome = { light: '#f8f2e9', dark: '#071216' };

function createPage({
    saved = null,
    systemDark = false,
    hasToggle = true,
    readBlocked = false,
    writeBlocked = false,
    legacyMediaQuery = false,
    mediaQueryAvailable = true,
} = {}) {
    function element(attributes = {}) {
        const values = new Map(Object.entries(attributes));
        const listeners = new Map();
        return {
            getAttribute: name => values.get(name) ?? null,
            setAttribute: (name, value) => values.set(name, value),
            addEventListener(name, listener) {
                const existing = listeners.get(name) ?? [];
                listeners.set(name, [...existing, listener]);
            },
            dispatch(name, event) {
                for (const listener of listeners.get(name) ?? []) listener(event);
            },
        };
    }

    const root = element();
    const button = element();
    const lightMeta = element({ content: chrome.light });
    const darkMeta = element({ content: chrome.dark });
    const documentEvents = element();
    const windowEvents = element();
    let osListener;
    const mq = { matches: systemDark };
    if (legacyMediaQuery) mq.addListener = listener => { osListener = listener; };
    else mq.addEventListener = (_name, listener) => { osListener = listener; };

    const localStorage = {
        getItem() {
            if (readBlocked) throw new Error('Storage read denied');
            return saved;
        },
        setItem(_key, value) {
            if (writeBlocked) throw new Error('Storage write denied');
            saved = value;
        },
    };
    const document = {
        documentElement: root,
        readyState: 'loading',
        querySelector(selector) {
            if (selector === '.theme-toggle') return hasToggle ? button : null;
            if (selector === 'meta[name="theme-color"][media="(prefers-color-scheme: light)"]') return lightMeta;
            if (selector === 'meta[name="theme-color"][media="(prefers-color-scheme: dark)"]') return darkMeta;
            throw new Error(`Unexpected selector: ${selector}`);
        },
        querySelectorAll(selector) {
            assert.equal(selector, 'meta[name="theme-color"]');
            return [lightMeta, darkMeta];
        },
        addEventListener: documentEvents.addEventListener,
    };
    vm.runInNewContext(source, {
        document,
        localStorage,
        window: {
            matchMedia: mediaQueryAvailable ? () => mq : undefined,
            addEventListener: windowEvents.addEventListener,
        },
    }, { filename: 'website/theme.js' });

    return {
        mode: () => root.getAttribute('data-theme-mode'),
        colors: () => [lightMeta, darkMeta].map(meta => meta.getAttribute('content')),
        pressed: () => button.getAttribute('aria-pressed'),
        saved: () => saved,
        finishLoading() {
            document.readyState = 'interactive';
            documentEvents.dispatch('DOMContentLoaded');
        },
        click: () => button.dispatch('click'),
        os(dark) {
            mq.matches = dark;
            osListener?.({ matches: dark });
        },
        externalChoice(value, { emit = true, key = 'quenderin_theme', sessionStorage = false } = {}) {
            if (!sessionStorage && (key === null || key === 'quenderin_theme')) saved = key === null ? null : value;
            if (emit) windowEvents.dispatch('storage', {
                key,
                newValue: key === null ? null : value,
                storageArea: sessionStorage ? {} : localStorage,
            });
        },
        blockReads: () => { readBlocked = true; },
    };
}

function expectMode(page, mode) {
    assert.equal(page.mode(), mode);
    assert.deepEqual(page.colors(), [chrome[mode], chrome[mode]]);
}

test('resolves before paint, then toggles once and restores the declared light chrome', () => {
    const page = createPage();
    expectMode(page, 'light');
    assert.equal(page.pressed(), null);
    page.finishLoading();
    assert.equal(page.pressed(), 'false');
    page.click();
    expectMode(page, 'dark');
    assert.equal(page.pressed(), 'true');
    assert.equal(page.saved(), 'dark');
    page.os(false);
    expectMode(page, 'dark');
    page.click();
    expectMode(page, 'light');
    assert.equal(page.saved(), 'light');
    const reloaded = createPage({ saved: page.saved(), systemDark: true });
    expectMode(reloaded, 'light');
});

test('saved explicit preferences override the opposite system appearance', () => {
    for (const saved of ['light', 'dark']) {
        const page = createPage({ saved, systemDark: saved === 'light' });
        expectMode(page, saved);
        page.finishLoading();
        page.os(saved === 'light');
        expectMode(page, saved);
    }
});

test('pages without a toggle follow the system and ignore invalid saved preferences', () => {
    for (const saved of [null, 'system', 'corrupt']) {
        const page = createPage({ saved, systemDark: true, hasToggle: false });
        expectMode(page, 'dark');
        page.finishLoading();
        page.os(false);
        expectMode(page, 'light');
    }
    expectMode(createPage({ mediaQueryAvailable: false }), 'light');
});

test('storage denial preserves system initialization and the current manual choice', () => {
    const denied = createPage({ systemDark: true, readBlocked: true, writeBlocked: true });
    expectMode(denied, 'dark');
    denied.finishLoading();
    denied.click();
    expectMode(denied, 'light');
    denied.os(true);
    expectMode(denied, 'light');

    // A readable older value must not undo a manual choice whose write failed.
    const writeOnlyDenied = createPage({ saved: 'light', writeBlocked: true });
    writeOnlyDenied.finishLoading();
    writeOnlyDenied.click();
    expectMode(writeOnlyDenied, 'dark');
    assert.equal(writeOnlyDenied.saved(), 'light');
    writeOnlyDenied.os(false);
    expectMode(writeOnlyDenied, 'dark');
});

test('an OS event rereads a cross-tab choice even before its storage event arrives', () => {
    const page = createPage({ systemDark: true });
    page.externalChoice('dark', { emit: false });
    page.os(false);
    expectMode(page, 'dark');
    page.externalChoice(null, { emit: false });
    page.os(true);
    expectMode(page, 'dark');
    page.os(false);
    expectMode(page, 'light');
});

test('cross-tab set, remove, clear and invalid values update the actual page and chrome', () => {
    const page = createPage({ hasToggle: false });
    page.externalChoice('dark');
    expectMode(page, 'dark');
    page.os(false);
    expectMode(page, 'dark');
    page.externalChoice(null);
    expectMode(page, 'light');
    page.os(true);
    expectMode(page, 'dark');
    page.externalChoice('light');
    expectMode(page, 'light');
    page.externalChoice(null, { key: null });
    expectMode(page, 'dark');
    page.externalChoice('corrupt');
    expectMode(page, 'dark');
    page.os(false);
    expectMode(page, 'light');
});

test('unrelated keys and session storage do not change the selected appearance', () => {
    const page = createPage({ systemDark: true });
    page.externalChoice('light', { key: 'unrelated' });
    expectMode(page, 'dark');
    page.externalChoice('light', { sessionStorage: true });
    expectMode(page, 'dark');
    page.os(true);
    expectMode(page, 'dark');
});

test('a later read failure keeps the known choice, and legacy OS listeners work', () => {
    const page = createPage({ saved: 'dark' });
    page.blockReads();
    page.os(false);
    expectMode(page, 'dark');
    const legacy = createPage({ legacyMediaQuery: true });
    legacy.os(true);
    expectMode(legacy, 'dark');
});
