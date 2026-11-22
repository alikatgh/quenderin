#!/usr/bin/env python3
"""Verify Android speech shared libraries and APK/AAB packaging (16 KiB ELF64 alignment & c++_static)."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEECH_LIBS = {'libquenderin_speech.so', 'libquenderin_speech_jni.so'}
spec = importlib.util.spec_from_file_location('diffusion_android', ROOT / 'scripts/verify_diffusion_android_package.py')
android_pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android_pkg)


def verify(libraries: Path, package: Path | None = None) -> dict:
    lock = json.loads((ROOT / 'shared/speech-runtime.json').read_text())
    stamp = json.loads((libraries / 'quenderin-speech-runtime.json').read_text())
    if stamp.get('revision') != lock['revision'] or stamp.get('abiVersion') != lock['abiVersion']:
        raise ValueError('Android speech source identity differs')
    if stamp.get('androidStl') != 'c++_static' or set(stamp.get('files', {})) != SPEECH_LIBS:
        raise ValueError('Android speech dependency policy differs')
    original = {name: android_pkg.bounded_file(libraries / 'arm64-v8a' / name) for name in SPEECH_LIBS}
    for name, data in original.items():
        if hashlib.sha256(data).hexdigest() != stamp['files'][name]:
            raise ValueError('Android speech checksum differs: ' + name)
    archive = zipfile.ZipFile(package) if package else None
    try:
        if archive:
            prefix = 'base/lib/arm64-v8a/' if package.suffix == '.aab' else 'lib/arm64-v8a/'
            entries = [i for i in archive.infolist() if i.filename.startswith(prefix) and i.filename.endswith('.so')]
            names = [i.filename[len(prefix):] for i in entries]
            if len(set(names)) != len(names) or any('/' in n for n in names):
                raise ValueError('Duplicate or nested packaged native speech library')
            info = dict(zip(names, entries))
            def get(name):
                item = info.get(name)
                if item is None or not 0 < item.file_size <= android_pkg.MAX_LIBRARY:
                    raise ValueError('Missing or oversized packaged dependency: ' + name)
                return archive.read(item)
        else:
            def get(name): return android_pkg.bounded_file(libraries / 'arm64-v8a' / name)
        pending, seen = list(SPEECH_LIBS), set()
        while pending:
            name = pending.pop()
            if name in seen: continue
            data = get(name)
            if name in SPEECH_LIBS and data != original[name]:
                raise ValueError('Packaged speech runtime differs: ' + name)
            dependencies = android_pkg.elf_dependencies(data)
            if 'libc++_shared.so' in dependencies:
                raise ValueError('Isolated speech runtime unexpectedly needs shared STL')
            pending.extend(dependencies - android_pkg.SYSTEM - seen)
            seen.add(name)
    finally:
        if archive: archive.close()
    return {
        'revision': lock['revision'],
        'verified': sorted(seen),
        'artifact': str(package or libraries),
        'alignment': 16384,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libraries', type=Path, required=True)
    parser.add_argument('--package', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.libraries, args.package)))


if __name__ == '__main__':
    main()
