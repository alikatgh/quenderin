import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const ROOT = path.resolve(import.meta.dirname, '..');

describe('macOS Electron audio entitlements and native speech build config', () => {
    it('configures Hardened Runtime audio-input entitlements for both main app and capture helpers', () => {
        const result = spawnSync('python3', [path.join(ROOT, 'scripts/verify_mac_electron_entitlements.py')], {
            cwd: ROOT,
            encoding: 'utf8',
        });
        expect(result.status, result.stderr).toBe(0);
        const parsed = JSON.parse(result.stdout) as {
            config: { entitlements: string; entitlementsInherit: string; requiredKeys: string[] };
        };
        expect(parsed.config.entitlements).toBe('brand/electron/entitlements.mac.plist');
        expect(parsed.config.entitlementsInherit).toBe('brand/electron/entitlements.mac.inherit.plist');
        expect(parsed.config.requiredKeys).toEqual(expect.arrayContaining([
            'com.apple.security.cs.allow-jit',
            'com.apple.security.cs.allow-unsigned-executable-memory',
            'com.apple.security.cs.disable-library-validation',
            'com.apple.security.device.audio-input',
        ]));
    });

    it('inspects signed macOS app and helper entitlements and fails closed when audio-input is missing', () => {
        const script = `
import plistlib, tempfile
from pathlib import Path
from types import SimpleNamespace
import sys
sys.path.insert(0, ${JSON.stringify(path.join(ROOT, 'scripts'))})
import verify_mac_electron_entitlements as v

with tempfile.TemporaryDirectory() as tmp:
    app = Path(tmp) / 'Quenderin.app'
    helper = app / 'Contents' / 'Frameworks' / 'Quenderin Helper (Renderer).app'
    (app / 'Contents').mkdir(parents=True)
    helper.mkdir(parents=True)
    (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps({
        'NSMicrophoneUsageDescription': 'Local dictation',
    }))
    good_xml = plistlib.dumps({k: True for k in v.REQUIRED_ENTITLEMENTS})
    missing_audio_xml = plistlib.dumps({k: True for k in v.REQUIRED_ENTITLEMENTS if 'audio-input' not in k})

    def good_runner(cmd, **kw):
        if '-dv' in cmd:
            return SimpleNamespace(returncode=0, stdout='', stderr='CodeDirectory v=20500 flags=0x10000(runtime)')
        return SimpleNamespace(returncode=0, stdout=good_xml, stderr=b'')

    res = v.verify_app(app, require_signed=True, runner=good_runner)
    assert len(res['bundles']) == 2
    assert all(b['entitlementsVerified'] for b in res['bundles'])

    def helper_missing_audio(cmd, **kw):
        if '-dv' in cmd:
            return SimpleNamespace(returncode=0, stdout='', stderr='CodeDirectory v=20500 flags=0x10000(runtime)')
        target = cmd[-1]
        return SimpleNamespace(returncode=0, stdout=missing_audio_xml if 'Helper' in target else good_xml, stderr=b'')

    try:
        v.verify_app(app, require_signed=True, runner=helper_missing_audio)
        raise AssertionError('Expected missing helper audio-input entitlement to fail')
    except ValueError as err:
        assert 'com.apple.security.device.audio-input' in str(err)
print('ok')
`;
        const run = spawnSync('python3', ['-c', script], { cwd: ROOT, encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout.trim()).toBe('ok');
    });

    it('preserves main-window, main-frame, exact-origin, and audio-only guards on Electron media and IPC handlers', () => {
        const mainSource = readFileSync(path.join(ROOT, 'src/electron/main.ts'), 'utf8');
        expect(mainSource).toContain("permission === 'media' && details.mediaType === 'audio'");
        expect(mainSource).toContain('details.isMainFrame && origin === new URL(trustedUrl).origin && contents.getURL() === trustedUrl');
        expect(mainSource).toContain("details.mediaTypes?.length === 1 && details.mediaTypes[0] === 'audio'");
        expect(mainSource).toContain('event.sender !== contents || event.senderFrame !== contents.mainFrame');
        expect(mainSource).toContain('event.senderFrame.url !== trustedUrl || contents.getURL() !== trustedUrl');
    });

    it('attaches pinned transcribe.cpp public headers and cross-platform flags in native/speech/CMakeLists.txt', () => {
        const cmake = readFileSync(path.join(ROOT, 'native/speech/CMakeLists.txt'), 'utf8');
        expect(cmake).toMatch(/find_package\(Python3 REQUIRED COMPONENTS Interpreter\)/);
        expect(cmake).toMatch(/add_subdirectory\("\$\{TRANSCRIBE_SOURCE\}" transcribe-cpp EXCLUDE_FROM_ALL\)/);
        expect(cmake).toMatch(/target_include_directories\(transcribe PUBLIC "\$\{TRANSCRIBE_SOURCE\}\/include"\)/);
        expect(cmake).toMatch(/TRANSCRIBE_USE_SYSTEM_BLAS OFF CACHE BOOL/);
        expect(cmake).toMatch(/RUNTIME_OUTPUT_DIRECTORY_\$\{configuration\}/);

        const py = readFileSync(path.join(ROOT, 'scripts/prepare_speech_runtime.py'), 'utf8');
        expect(py).toContain('-DPython3_EXECUTABLE=');
        expect(py).toContain('-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded');
        expect(py).toContain('"-A", arch_flag');
    });
});
