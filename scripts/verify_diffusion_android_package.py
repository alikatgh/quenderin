#!/usr/bin/env python3
"""Check the actual Android image DSOs and APK/AAB dependency closure, without running them."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IMAGES = {'libquenderin_diffusion.so', 'libquenderin_diffusion_jni.so'}
SYSTEM = {'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so', 'libz.so',
          'libvulkan.so', 'libjnigraphics.so', 'libEGL.so', 'libGLESv2.so',
          'libGLESv3.so', 'libOpenSLES.so', 'libmediandk.so', 'libaaudio.so'}
MAX_LIBRARY = 512 * 1024 * 1024


def elf_dependencies(data: bytes) -> set[str]:
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Expected little-endian ELF64')
    header = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
    if header[1] != 183 or header[0] != 3:
        raise ValueError('Expected an arm64 shared library')
    offset, entry_size, count = header[4], header[8], header[9]
    if entry_size != 56 or not 0 < count <= 256 or offset + count * 56 > len(data):
        raise ValueError('Invalid ELF program table')
    loads, dynamics = [], []
    for index in range(count):
        p = struct.unpack_from('<IIQQQQQQ', data, offset + index * 56)
        kind, _, start, address, _, size, memory, alignment = p
        if start + size > len(data) or size > memory:
            raise ValueError('Invalid ELF segment range')
        if kind == 1:
            if alignment < 16384 or alignment & (alignment - 1) or (address - start) % alignment:
                raise ValueError('ELF LOAD segment is not 16 KiB compatible')
            loads.append((address, start, size))
        elif kind == 2:
            dynamics.append((start, address, size))
    if not loads or len(dynamics) != 1:
        raise ValueError('ELF needs LOAD and one DYNAMIC segment')
    start, address, size = dynamics[0]
    if not any(v <= address and address + size <= v + n and start == s + address - v for v, s, n in loads):
        raise ValueError('ELF dynamic table does not map through a LOAD segment')
    if size % 16:
        raise ValueError('Invalid ELF dynamic table')
    needed, table_address, table_size, ended = [], None, None, False
    for place in range(start, start + size, 16):
        tag, value = struct.unpack_from('<qQ', data, place)
        if tag == 0:
            ended = True
            break
        if tag == 1: needed.append(value)
        elif tag == 5: table_address = value
        elif tag == 10: table_size = value
    if not ended or table_address is None or not table_size:
        raise ValueError('Missing ELF dynamic strings')
    ranges = [(s + table_address - v, table_size) for v, s, n in loads
              if v <= table_address and table_address + table_size <= v + n]
    if len(ranges) != 1:
        raise ValueError('Invalid ELF string table range')
    base, length = ranges[0]
    result = set()
    for place in needed:
        if place >= length:
            raise ValueError('Invalid ELF dependency name offset')
        end = data.find(b'\0', base + place, base + length)
        if end < 0:
            raise ValueError('Unterminated ELF dependency name')
        name = data[base + place:end].decode('ascii')
        if not name.startswith('lib') or not name.endswith('.so') or '/' in name or '\\' in name:
            raise ValueError('Unexpected ELF dependency name')
        result.add(name)
    return result


def bounded_file(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_LIBRARY:
        raise ValueError('Invalid or oversized native library')
    return path.read_bytes()


def verify(libraries: Path, package: Path | None = None) -> dict:
    lock = json.loads((ROOT / 'shared/diffusion-runtime.json').read_text())
    stamp = json.loads((libraries / 'quenderin-diffusion-runtime.json').read_text())
    for key in ('revision', 'abiVersion', 'submodules'):
        if stamp.get(key) != lock[key]: raise ValueError('Android image source identity differs')
    if stamp.get('androidStl') != 'c++_static' or set(stamp.get('files', {})) != IMAGES:
        raise ValueError('Android image dependency policy differs')
    original = {name: bounded_file(libraries / 'arm64-v8a' / name) for name in IMAGES}
    for name, data in original.items():
        if hashlib.sha256(data).hexdigest() != stamp['files'][name]:
            raise ValueError('Android image checksum differs: ' + name)
    archive = zipfile.ZipFile(package) if package else None
    try:
        if archive:
            prefix = 'base/lib/arm64-v8a/' if package.suffix == '.aab' else 'lib/arm64-v8a/'
            entries = [i for i in archive.infolist() if i.filename.startswith(prefix) and i.filename.endswith('.so')]
            names = [i.filename[len(prefix):] for i in entries]
            if len(set(names)) != len(names) or any('/' in n for n in names):
                raise ValueError('Duplicate or nested packaged native library')
            info = dict(zip(names, entries))
            def get(name):
                item = info.get(name)
                if item is None or not 0 < item.file_size <= MAX_LIBRARY:
                    raise ValueError('Missing or oversized packaged dependency: ' + name)
                return archive.read(item)
        else:
            def get(name): return bounded_file(libraries / 'arm64-v8a' / name)
        pending, seen = list(IMAGES), set()
        while pending:
            name = pending.pop()
            if name in seen: continue
            data = get(name)
            if name in IMAGES and data != original[name]:
                raise ValueError('Packaged image runtime differs: ' + name)
            dependencies = elf_dependencies(data)
            if 'libc++_shared.so' in dependencies:
                raise ValueError('Isolated image runtime unexpectedly needs shared STL')
            pending.extend(dependencies - SYSTEM - seen)
            seen.add(name)
    finally:
        if archive: archive.close()
    return {'revision': lock['revision'], 'verified': sorted(seen),
            'artifact': str(package or libraries), 'alignment': 16384}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libraries', type=Path, required=True)
    parser.add_argument('--package', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.libraries, args.package)))


if __name__ == '__main__': main()
