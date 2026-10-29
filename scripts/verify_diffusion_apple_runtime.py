#!/usr/bin/env python3
"""Verify isolated Apple image frameworks without downloading or loading model weights."""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STAMP = 'quenderin-diffusion-runtime.json'
DEFAULT = ROOT / 'apple/QuenderinKit/Frameworks/QuenderinDiffusion.xcframework'
APPLE_TARGETS = {'ios': (2, 'iPhoneOS', 'MinimumOSVersion', '16.4'),
                 'ios-simulator': (7, 'iPhoneSimulator', 'MinimumOSVersion', '16.4'),
                 'macos': (1, 'MacOSX', 'LSMinimumSystemVersion', '13.3')}
spec = importlib.util.spec_from_file_location('prism_payload', ROOT / 'scripts/verify_prism_apple_runtime.py')
prism = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prism)


def deployment_version(value: str) -> int:
    if not isinstance(value, str) or re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', value) is None:
        raise ValueError('Image deployment minimum is missing or malformed')
    parts = list(map(int, value.split('.')))
    major, minor, patch = parts + [0] * (3 - len(parts))
    if not 0 < major <= 65535 or not 0 <= minor <= 255 or not 0 <= patch <= 255:
        raise ValueError('Image deployment minimum is outside the Mach-O version range')
    return major << 16 | minor << 8 | patch


def framework_metadata(directory: Path, target: str, payload: dict, app_build: str | None = None) -> dict:
    info_path = directory / 'Info.plist'
    if not info_path.is_file(): info_path = directory / 'Resources/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    expected = {'CFBundleIdentifier':'org.quenderin.diffusion', 'CFBundlePackageType':'FMWK',
                'CFBundleShortVersionString':'1.0.0', 'CFBundleVersion':'1',
                'CFBundleExecutable':'QuenderinDiffusion', 'CFBundleName':'QuenderinDiffusion',
                'CFBundleInfoDictionaryVersion':'6.0'}
    actual = {key: info.get(key) for key in expected}
    if any(not isinstance(value, str) for value in actual.values()):
        raise ValueError('Image framework bundle identity/version is invalid')
    if app_build is not None and app_build.isdigit() and actual['CFBundleVersion'] == app_build:
        actual['CFBundleVersion'] = expected['CFBundleVersion']
    if actual != expected:
        raise ValueError('Image framework bundle identity/version is invalid')
    if target not in APPLE_TARGETS:
        raise ValueError('Unexpected image framework platform')
    platform, supported, minimum_key, minimum = APPLE_TARGETS[target]
    if info.get('CFBundleSupportedPlatforms') != [supported]:
        raise ValueError('Image framework supported platforms differ from its target')
    declared_minimum = deployment_version(info.get(minimum_key))
    if declared_minimum != deployment_version(minimum) or not payload or any(
            value['platform'] != platform or value['minimumOS'] != declared_minimum for value in payload.values()):
        raise ValueError('Image framework platform or deployment minimum differs from its compiled target')
    expected.update(CFBundleSupportedPlatforms=[supported], **{minimum_key: minimum})
    return expected


def description(framework: Path, execute: bool = False) -> dict:
    lock = json.loads((ROOT / 'shared/diffusion-runtime.json').read_text())
    info = plistlib.loads((framework / 'Info.plist').read_bytes())
    slices = []
    for item in info['AvailableLibraries']:
        directory = framework / item['LibraryIdentifier'] / item['LibraryPath']
        binary = directory / 'QuenderinDiffusion'
        if not binary.exists():
            binary = directory / 'Versions/A/QuenderinDiffusion'
        payload = prism.macho_payload(binary)
        identity = (item['SupportedPlatform'], item.get('SupportedPlatformVariant'))
        target = {('ios', None):'ios', ('ios', 'simulator'):'ios-simulator', ('macos', None):'macos'}.get(identity)
        if target is None:
            raise ValueError('Unexpected image framework platform')
        expected = {'arm64'} if target == 'ios' else {'arm64', 'x86_64'}
        if set(payload) != expected:
            raise ValueError('Image framework architecture set differs')
        subprocess.run(['python3', str(ROOT / 'scripts/prepare_diffusion_runtime.py'), 'verify-library',
                        '--library', str(binary), '--platform', 'apple'], check=True, capture_output=True)
        symbols = subprocess.check_output(['xcrun', 'nm', '-a', str(binary)], text=True)
        if '_OBJC_CLASS_$_GGMLMetalClass' in symbols:
            raise ValueError('Diffusion leaked llama Metal Objective-C class identity')
        header = directory / 'Headers/quenderin_diffusion.h'
        if not header.is_file() or not (directory / 'Modules/module.modulemap').is_file():
            raise ValueError('Image framework is missing its public C/Swift module')
        slices.append({'id': item['LibraryIdentifier'], 'platform': item['SupportedPlatform'],
                       'payload': payload, 'headerSha256': hashlib.sha256(header.read_bytes()).hexdigest(),
                       'bundleMetadata': framework_metadata(directory, target, payload)})
        if identity[1] is not None:
            slices[-1]['variant'] = identity[1]
        if execute and item['SupportedPlatform'] == 'macos':
            library = ctypes.CDLL(str(binary))
            library.quenderin_diffusion_abi.restype = ctypes.c_uint32
            library.quenderin_diffusion_revision.restype = ctypes.c_char_p
            if library.quenderin_diffusion_abi() != 1 or library.quenderin_diffusion_revision().decode() != lock['revision']:
                raise ValueError('Compiled image runtime identity mismatch')
    identities = [(s['platform'], s.get('variant')) for s in slices]
    if len(set(identities)) != len(identities) or not {('ios', None), ('macos', None)}.issubset(identities):
        raise ValueError('Exactly one iOS device and one universal macOS image framework, with at most one iOS simulator slice, required')
    return {'version': 1, 'repository': lock['repository'], 'revision': lock['revision'],
            'abiVersion': lock['abiVersion'], 'submodules': lock['submodules'], 'slices': slices}


def verify(framework: Path) -> dict:
    stamp = json.loads((framework / STAMP).read_text())
    actual = description(framework)
    if stamp != actual:
        raise ValueError('Image framework seal does not match source/binary identity')
    return actual


def source_framework(root: Path) -> Path:
    return root / 'apple/QuenderinKit/Frameworks/QuenderinDiffusion.xcframework'


def embed_evidence(app: Path, target: str, root: Path = ROOT) -> None:
    stamp = verify(source_framework(root))
    resources = app / 'Contents/Resources' if target == 'macos' else app
    resources.mkdir(parents=True, exist_ok=True)
    (resources / 'quenderin-diffusion-release.json').write_text(json.dumps(stamp, indent=2) + '\n')
    (resources / 'quenderin-image-model-catalog.json').write_bytes((root / 'shared/image-model-catalog.json').read_bytes())


def verify_app(app: Path, target: str, root: Path = ROOT, signed: bool = False) -> dict:
    if target not in ('ios', 'macos'): raise ValueError('Image export must be iOS device or macOS')
    stamp = verify(source_framework(root))
    expected = next(s for s in stamp['slices'] if s['platform'] == target and s.get('variant') is None)
    contents = app / 'Contents' if target == 'macos' else app
    resources = contents / 'Resources' if target == 'macos' else contents
    native = contents / 'Frameworks/QuenderinDiffusion.framework'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    # Managed macOS export may sync the framework build to the signed app build.
    app_build = str(info.get('CFBundleVersion', '')) if signed and target == 'macos' else None
    binary = native / ('Versions/A/QuenderinDiffusion' if target == 'macos' else 'QuenderinDiffusion')
    payload = prism.macho_payload(binary)
    if framework_metadata(native, target, payload, app_build) != expected['bundleMetadata']:
        raise ValueError('App image framework bundle metadata differs')
    if payload != expected['payload']:
        raise ValueError('App image framework payload/architectures differ from verified source')
    executable = contents / ('MacOS/' + info['CFBundleExecutable'] if target == 'macos' else info['CFBundleExecutable'])
    app_payload = prism.macho_payload(executable)
    app_minimum = deployment_version(info.get(APPLE_TARGETS[target][2]))
    if set(app_payload) != set(payload) or any(v['platform'] != (1 if target == 'macos' else 2)
            or v['minimumOS'] != app_minimum or app_minimum < payload[a]['minimumOS'] for a, v in app_payload.items()):
        raise ValueError('App/image framework platform, architecture or minimum OS differs')
    linked = prism.run('xcrun', 'otool', '-L', str(executable))
    if '@rpath/QuenderinDiffusion.framework/' not in linked:
        raise ValueError('App executable does not link the verified image framework')
    if signed:
        prism.run('codesign', '--verify', '--strict', str(native))
        details = prism.run('codesign', '-d', '--verbose=4', str(native))
        if 'TeamIdentifier=9M2B2P4KSA' not in details or 'Signature=adhoc' in details:
            raise ValueError('Image framework signature does not belong to the distribution team')
        if json.loads((resources / 'quenderin-diffusion-release.json').read_text()) != stamp:
            raise ValueError('App image runtime provenance differs')
        if (resources / 'quenderin-image-model-catalog.json').read_bytes() != (root / 'shared/image-model-catalog.json').read_bytes():
            raise ValueError('App image catalog differs')
    return {'revision': stamp['revision'], 'abiVersion': stamp['abiVersion'], 'architectures': sorted(payload)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('seal', 'verify'):
        item = commands.add_parser(name); item.add_argument('--framework', type=Path, default=DEFAULT)
    args = parser.parse_args()
    if args.command == 'seal':
        if (args.framework / STAMP).exists(): raise ValueError('Existing image seal is preserved')
        result = description(args.framework, execute=True)
        with (args.framework / STAMP).open('x') as stream: stream.write(json.dumps(result, indent=2) + '\n')
    else: result = verify(args.framework)
    print(json.dumps({'revision': result['revision'], 'abiVersion': result['abiVersion'], 'verified': str(args.framework)}))


if __name__ == '__main__':
    main()
