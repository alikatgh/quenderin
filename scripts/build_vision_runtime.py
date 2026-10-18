#!/usr/bin/env python3
"""Compile and stage the exact bounded desktop vision worker, without model weights.

Hosted target-OS builds only. A static worker owns exactly one Prism llama/GGML/
mtmd runtime in its child process. Native apps include the static bridge target
in their existing Prism runtime, rather than loading this executable.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import platform
import os
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
import prepare_prism_runtime as runtime
import verify_prism_apple_runtime as apple_runtime
from build_desktop_diffusion import linux_dependencies, windows_tools
ROOT = Path(__file__).resolve().parent.parent
STAMP = 'quenderin-vision-runtime.json'
PLATFORMS = {'Darwin': 'mac', 'Windows': 'win', 'Linux': 'linux'}
ARCHES = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64', 'armv7l': 'armv7l'}

def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def host() -> tuple[str, str]:
    try: return PLATFORMS[platform.system()], ARCHES[platform.machine()]
    except KeyError as e: raise ValueError('Unsupported vision build host') from e

def probe(executable: Path) -> dict:
    result = subprocess.run([str(executable.resolve()), '--abi'], check=True, capture_output=True, text=True, timeout=30)
    if len(result.stdout) > 4096: raise ValueError('Excessive vision ABI probe output')
    info = json.loads(result.stdout)
    if info != {'abi': 1, 'revision': runtime.LOCK['revision'], 'visionPatchSha256': runtime.LOCK['visionPatch']['sha256']}:
        raise ValueError('Compiled vision ABI/source patch identity differs')
    return info

def dependencies(executable: Path, os_name: str) -> None:
    if os_name == 'mac':
        output = subprocess.check_output(['otool', '-L', str(executable)], text=True, timeout=30)
        for line in output.splitlines()[1:]:
            name = line.strip().split(' (', 1)[0]
            if not name.startswith(('/usr/lib/', '/System/Library/')):
                raise ValueError('Vision worker has a non-system macOS dependency')
    elif os_name == 'linux':
        output = subprocess.check_output(['ldd', str(executable)], text=True, timeout=30)
        allowed = re.compile(r'^(?:lib(?:c|m|pthread|dl|rt)\.so(?:\.\d+)*|ld-linux[^/]*)$')
        for name in linux_dependencies(output):
            if not allowed.fullmatch(name): raise ValueError('Vision worker must statically link its non-system runtime: ' + name)
    else:
        windows_tools()
        output = subprocess.check_output(['dumpbin', '/NOLOGO', '/DEPENDENTS', str(executable)], text=True, timeout=30)
        names = re.findall(r'^\s+([A-Za-z0-9_.-]+\.dll)\s*$', output, re.MULTILINE | re.IGNORECASE)
        if not names: raise ValueError('Could not inspect vision PE dependencies')
        system = Path(os.environ['SystemRoot']) / 'System32'
        for name in names:
            lower = name.lower()
            if lower.startswith(('vcruntime', 'msvcp', 'libgcc', 'libstdc++')):
                raise ValueError('Vision worker must use the static C++ CRT')
            if not lower.startswith(('api-ms-win-', 'ext-ms-win-')) and not (system / name).is_file():
                raise ValueError('Vision worker has an unresolved Windows dependency')


def verify(directory: Path, *, packaged: bool = False) -> dict:
    stamp = json.loads((directory / STAMP).read_text())
    os_name, arch = host()
    executable = directory / ('quenderin-vision-cli.exe' if os_name == 'win' else 'quenderin-vision-cli')
    if (directory.is_symlink() or executable.is_symlink() or not executable.is_file()
            or stamp.get('platform') != os_name or stamp.get('arch') != arch
            or stamp.get('visionModelsSha256') != sha(ROOT / 'shared/vision-models.json')
            or stamp.get('source') != runtime.provenance()):
        raise ValueError('Vision executable, manifest or source provenance differs')
    notice = directory / 'THIRD_PARTY_NOTICES.txt'
    if notice.is_symlink() or not notice.is_file() or sha(notice) != stamp.get('noticesSha256'):
        raise ValueError('Vision runtime redistribution notices differ')
    if os_name == 'mac':
        payload = apple_runtime.macho_payload(executable)
        expected_arch = 'x86_64' if arch == 'x64' else arch
        if set(payload) != {expected_arch} or any(x['platform'] != 1 for x in payload.values()) or payload != stamp.get('machoPayload'):
            raise ValueError('Vision Mach-O executable code or architecture changed')
    if not (packaged and os_name == 'mac') and (stamp.get('sha256') != sha(executable) or stamp.get('bytes') != executable.stat().st_size):
        raise ValueError('Vision executable whole-file integrity differs')
    expected_files = {STAMP, executable.name, notice.name}
    if {p.name for p in directory.iterdir()} != expected_files:
        raise ValueError('Vision resources contain unexpected files or dependencies')
    probe(executable)
    dependencies(executable, os_name)
    return stamp

def build(source: Path, work: Path, destination: Path | None, jobs: int) -> dict:
    identity = runtime.verify(source)
    if identity.get('visionABI') != 1: raise ValueError('Verified vision source ABI is unavailable')
    os_name, arch = host()
    destination = destination or ROOT / 'build/vision' / f'{os_name}-{arch}'
    for path in (work, destination):
        if path.exists() or path.is_symlink(): raise ValueError('Build and staging destinations must be new; existing files are preserved')
    subprocess.run([sys.executable, str(ROOT / 'scripts/generate_vision_models.py'), '--check'], check=True)
    command = ['cmake', '-S', str(ROOT / 'native/vision'), '-B', str(work), '-DCMAKE_BUILD_TYPE=Release',
               '-DPRISM_SOURCE_DIR=' + str(source.resolve()), '-DGGML_NATIVE=OFF', '-DGGML_OPENMP=OFF', '-DGGML_BACKEND_DL=OFF', '-DBUILD_SHARED_LIBS=OFF']
    if os_name == 'mac': command += ['-DGGML_METAL=ON', '-DGGML_METAL_EMBED_LIBRARY=ON', '-DGGML_ACCELERATE=ON']
    if os_name == 'win': command += ['-A', 'ARM64' if arch == 'arm64' else 'x64', '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded']
    subprocess.run(command, check=True)
    subprocess.run(['cmake', '--build', str(work), '--config', 'Release', '--target', 'quenderin-vision-cli', '--parallel', str(jobs)], check=True)
    executable = work / 'bin' / ('quenderin-vision-cli.exe' if os_name == 'win' else 'quenderin-vision-cli')
    probe(executable)
    destination.mkdir(parents=True, exist_ok=False)
    staged = destination / executable.name
    # Exclusive creation protects a concurrent packager, even with a new parent.
    with executable.open('rb') as src, staged.open('xb') as dst: shutil.copyfileobj(src, dst)
    staged.chmod(executable.stat().st_mode & 0o777)
    notices = (source / 'LICENSE').read_text()
    if os_name == 'linux':
        for package in ('libstdc++6', 'libgcc-s1'):
            notice = Path('/usr/share/doc') / package / 'copyright'
            if not notice.is_file(): raise ValueError('Static GNU runtime redistribution notice is unavailable')
            notices += '\n\n' + package + '\n' + notice.read_text()
    notice = destination / 'THIRD_PARTY_NOTICES.txt'
    with notice.open('x') as out: out.write(notices)
    stamp = dict(version=1, abi=1, platform=os_name, arch=arch, source=identity,
                 visionModelsSha256=sha(ROOT / 'shared/vision-models.json'), sha256=sha(staged), bytes=staged.stat().st_size,
                 noticesSha256=sha(notice))
    if os_name == 'mac': stamp['machoPayload'] = apple_runtime.macho_payload(staged)
    with (destination / STAMP).open('x') as out: json.dump(stamp, out, indent=2); out.write('\n')
    return verify(destination)

def main():
    p = argparse.ArgumentParser(description=__doc__); sub = p.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build'); b.add_argument('--source', type=Path, required=True); b.add_argument('--work', type=Path, required=True); b.add_argument('--destination', type=Path); b.add_argument('--jobs', type=int, default=3)
    v = sub.add_parser('verify'); v.add_argument('--directory', type=Path, required=True); v.add_argument('--packaged', action='store_true')
    a = p.parse_args()
    try:
        if a.command == 'build':
            if not 1 <= a.jobs <= 8: raise ValueError('jobs must be 1..8')
            result = build(a.source, a.work, a.destination, a.jobs)
        else: result = verify(a.directory, packaged=a.packaged)
        print(json.dumps(result))
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as e: p.exit(1, f'Vision runtime rejected: {e}\n')
if __name__ == '__main__': main()
