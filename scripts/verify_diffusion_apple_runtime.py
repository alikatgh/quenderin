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
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STAMP = 'quenderin-diffusion-runtime.json'
DEFAULT = ROOT / 'apple/QuenderinKit/Frameworks/QuenderinDiffusion.xcframework'
spec = importlib.util.spec_from_file_location('prism_payload', ROOT / 'scripts/verify_prism_apple_runtime.py')
prism = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prism)


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
        if item.get('SupportedPlatformVariant') is not None or item['SupportedPlatform'] not in ('ios', 'macos'):
            raise ValueError('Unexpected image framework platform')
        expected = {'arm64'} if item['SupportedPlatform'] == 'ios' else {'arm64', 'x86_64'}
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
                       'payload': payload, 'headerSha256': hashlib.sha256(header.read_bytes()).hexdigest()})
        if execute and item['SupportedPlatform'] == 'macos':
            library = ctypes.CDLL(str(binary))
            library.quenderin_diffusion_abi.restype = ctypes.c_uint32
            library.quenderin_diffusion_revision.restype = ctypes.c_char_p
            if library.quenderin_diffusion_abi() != 1 or library.quenderin_diffusion_revision().decode() != lock['revision']:
                raise ValueError('Compiled image runtime identity mismatch')
    if sorted(s['platform'] for s in slices) != ['ios', 'macos']:
        raise ValueError('Exactly one iOS and one universal macOS image framework required')
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
    expected = next(s for s in stamp['slices'] if s['platform'] == target)
    contents = app / 'Contents' if target == 'macos' else app
    resources = contents / 'Resources' if target == 'macos' else contents
    native = contents / 'Frameworks/QuenderinDiffusion.framework'
    binary = native / ('Versions/A/QuenderinDiffusion' if target == 'macos' else 'QuenderinDiffusion')
    payload = prism.macho_payload(binary)
    if payload != expected['payload']:
        raise ValueError('App image framework payload/architectures differ from verified source')
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    executable = contents / ('MacOS/' + info['CFBundleExecutable'] if target == 'macos' else info['CFBundleExecutable'])
    app_payload = prism.macho_payload(executable)
    if set(app_payload) != set(payload) or any(v['platform'] != (1 if target == 'macos' else 2)
            or v['minimumOS'] < payload[a]['minimumOS'] for a, v in app_payload.items()):
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
