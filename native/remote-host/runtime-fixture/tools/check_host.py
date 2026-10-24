"""Verify pinned source roots, manifests and the fixture's actual import closure."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import runpy
import subprocess
import sys

ALIASES = {
    '@dsh-remote/protocol': 'packages/protocol/src/index.ts',
    '@quenderin/patched-host-bridge': 'packages/plugin/src/harness-remote-bridge.ts',
    '@quenderin/upstream-gateway-switch': 'packages/plugin/src/typert-gateway-switch.ts',
    '@quenderin/host-policy': 'packages/plugin/src/quenderin-host-policy.mjs',
    '@quenderin/plugin-route-bridge': 'packages/plugin/src/plugin-route-bridge.ts',
    '@quenderin/plugin-route-dispatcher': 'packages/plugin/src/plugin-route-dispatcher.ts',
    '@quenderin/connection-controller': 'packages/plugin/src/connection-controller.ts',
    '@quenderin/rpc-router': 'packages/plugin/src/rpc-router.ts',
    '@quenderin/bot-runtime': 'packages/plugin/src/quenderin-bot-runtime.mjs',
}
BOT_ALIASES = {'@quenderin/pinned-bot-channel': 'ds-bot/src/host/channel.js',
               '@quenderin/pinned-bot-store': 'ds-bot/src/host/store.js'}
EXTERNALS = {'zod', '@xterm/headless', '@xterm/addon-serialize'}
POLICIES = ['quenderin-host-policy.mjs', 'quenderin-host-policy.d.mts',
            'quenderin-bot-read-policy.mjs', 'quenderin-bot-read-policy.d.mts',
            'quenderin-bot-runtime.mjs', 'quenderin-bot-runtime.d.mts']
COMPANIONS = {**{'packages/plugin/src/' + name: name for name in POLICIES},
              **{'packages/protocol/src/' + name: name for name in ['quenderin-bot-read-wire.mjs', 'quenderin-bot-read-wire.d.mts']}}


def git(checkout, *args, data=None):
    # Do not load user/system Git configuration or replacement objects.
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
           'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_TERMINAL_PROMPT': '0'}
    return subprocess.run(['git', '--no-pager', '--no-replace-objects', '-C', str(checkout), *args],
                          input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=env, timeout=3, check=True).stdout


def imports(source):
    """Conservative literal import reader for this pinned, inspected TS closure."""
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    lines = source.splitlines()
    result = []
    for index, line in enumerate(lines):
        start = line.strip()
        if not re.match(r'^(?:import|export)\s', start) or re.match(r'^(?:import|export)\s+type\b', start):
            continue
        if start.startswith('export ') and not re.match(r'^export\s+(?:\*|\{)', start):
            continue
        declaration = start
        for following in range(index + 1, min(index + 30, len(lines))):
            if re.search(r'\bfrom\s*[\'\"]', declaration) or re.match(r'^import\s*[\'\"]', declaration):
                break
            if re.match(r'^(?:import|export)\s', lines[following].strip()):
                break
            declaration += '\n' + lines[following]
        match = re.search(r'\bfrom\s*[\'\"]([^\'\"]+)[\'\"]', declaration) or re.match(r'^import\s*[\'\"]([^\'\"]+)[\'\"]', declaration)
        if match:
            result.append(match[1])
    for match in re.finditer(r'\b(?:import|require)\s*\(\s*([^\s])', source):
        if match[1] not in "'\"":
            raise ValueError('Nonliteral source import is outside the reviewed closure')
    result.extend(re.findall(r'\b(?:import|require)\s*\(\s*[\'\"]([^\'\"]+)[\'\"]', source))
    return result


def no_links(checkout, path):
    current = path
    while current != checkout:
        if current.is_symlink():
            raise ValueError('Linked source or manifest is forbidden')
        current = current.parent


def verify_checkout(checkout, spec, transform, companion, aliases=ALIASES, companion_paths=COMPANIONS, selected_only=False):
    checkout = checkout.absolute()
    if checkout.is_symlink() or not checkout.is_dir():
        raise ValueError('Regular pinned Host checkout required')
    if git(checkout, 'rev-parse', 'HEAD').decode().strip() != spec['revision']:
        raise ValueError('Pinned Host revision differs')
    entries = {}
    for entry in git(checkout, 'ls-tree', '-r', '-z', '--full-tree', spec['revision']).split(b'\0'):
        if entry:
            meta, path = entry.split(b'\t', 1)
            mode, kind, oid = meta.decode().split()
            entries[path.decode()] = (mode, kind, oid)
    roots = spec.get('sourceRoots') or sorted({path.split('/src/')[0] + '/src' for path in entries if path.startswith('packages/') and '/src/' in path})
    package_roots = {str(PurePosixPath(root).parent) for root in roots}
    manifest_dirs = package_roots | {'.'}
    relevant = set(spec['files']) if selected_only else {path for path in entries if any(path.startswith(root + '/') for root in roots)
                or (str(PurePosixPath(path).parent) in manifest_dirs and (PurePosixPath(path).name == 'package.json'
                    or re.fullmatch(r'tsconfig[^/]*\.json', PurePosixPath(path).name)))}
    if not roots or not set(spec['files']).issubset(relevant) or not set(aliases.values()).difference(companion_paths).issubset(relevant):
        raise ValueError('Pinned source closure is incomplete')
    # One batch reads exact immutable Git blobs, without checkout filters or dist.
    ordered = sorted(relevant)
    objects = git(checkout, 'cat-file', '--batch', data=('\n'.join(entries[path][2] for path in ordered) + '\n').encode())
    expected = {}
    offset = 0
    for path in ordered:
        mode, kind, oid = entries[path]
        if mode not in {'100644', '100755'} or kind != 'blob':
            raise ValueError('Pinned source links are forbidden')
        end = objects.index(b'\n', offset)
        actual_oid, actual_kind, size = objects[offset:end].decode().split()
        size = int(size)
        if size > 1_048_576 or actual_oid != oid or actual_kind != 'blob':
            raise ValueError('Pinned source blob identity differs')
        value = objects[end + 1:end + 1 + size]
        offset = end + 2 + size
        if hashlib.sha1(f'blob {size}\0'.encode() + value).hexdigest() != oid:
            raise ValueError('Pinned source blob digest differs')
        if path in spec['files']:
            if hashlib.sha256(value).hexdigest() != spec['files'][path]:
                raise ValueError('Pinned original differs')
            value = transform(path, value.decode()).encode()
        expected[path] = value
    for path, name in companion_paths.items():
        expected[path] = (companion / name).read_bytes()
    for path, value in expected.items():
        file = checkout / path
        no_links(checkout, file)
        if not file.is_file() or file.read_bytes() != value:
            raise ValueError('Unapproved Host source or manifest differs')
    # Exact membership rejects adjacent JS, nested package.json and new modules.
    for root in roots:
        directory = checkout / root
        no_links(checkout, directory)
        for current, directories, files in os.walk(directory, followlinks=False):
            for name in directories + files:
                if (Path(current) / name).is_symlink():
                    raise ValueError('Linked source or manifest is forbidden')
            for name in files:
                if (Path(current) / name).relative_to(checkout).as_posix() not in expected:
                    raise ValueError('Extra Host source is forbidden')
    for directory in manifest_dirs:
        for file in (checkout / directory).iterdir():
            if file.name == 'package.json' or re.fullmatch(r'tsconfig[^/]*\.json', file.name):
                no_links(checkout, file)
                if file.relative_to(checkout).as_posix() not in expected:
                    raise ValueError('Extra package or TypeScript manifest is forbidden')
    # Local imports must stay in verified roots. Other runtime imports are Node
    # builtins or the exact fixture-lock packages selected by the Vite resolver.
    pending = list(aliases.values())
    closure, external = set(), set()
    while pending:
        path = pending.pop()
        if path in closure:
            continue
        closure.add(path)
        for module in imports(expected[path].decode()):
            if module in aliases:
                pending.append(aliases[module])
            elif module.startswith('.'):
                target = posixpath.normpath(posixpath.join(posixpath.dirname(path), module))
                candidates = [target, re.sub(r'\.js$', '.ts', target), re.sub(r'\.mjs$', '.mts', target), target + '/index.ts']
                resolved = next((candidate for candidate in candidates if candidate in expected), None)
                if resolved is None:
                    raise ValueError('Relative import escapes verified Host source')
                pending.append(resolved)
            elif module.startswith('node:') or module.startswith('@deepseek-ai/') or module in EXTERNALS:
                external.add(module)
            else:
                raise ValueError('External import is outside the fixture closure')
    return {'sourceFiles': len(expected), 'runtimeSourceClosure': len(closure), 'externalImports': sorted(external)}


def main():
    companion = Path(__file__).resolve().parents[2]
    fixture = Path(__file__).resolve().parents[1]
    config = (fixture / 'vitest.config.mjs').read_text()
    actual_aliases = dict(re.findall(r"if \(source === '([^']+)'\) return resolve\(upstream, '([^']+)'\)", config))
    if actual_aliases != ALIASES:
        raise ValueError('Fixture source aliases differ from the reviewed closure')
    spec = json.loads((companion / 'upstream.json').read_text())
    transform = runpy.run_path(str(companion / 'tools/prepare_host.py'))['transform']
    result = verify_checkout(Path(sys.argv[1]), spec, transform, companion)
    actual_bot_aliases = dict(re.findall(r"if \(source === '([^']+)'\) return resolve\(bot, '([^']+)'\)", config))
    if actual_bot_aliases != BOT_ALIASES or not os.environ.get('QUENDERIN_BOT_SOURCE', '').startswith('/'):
        raise ValueError('Exact Bot source aliases and absolute checkout required')
    bot_spec = json.loads((companion / 'bot-upstream.json').read_text())
    bot_patch = runpy.run_path(str(companion / 'tools/prepare_bot.py'))
    result['bot'] = verify_checkout(Path(os.environ['QUENDERIN_BOT_SOURCE']), bot_spec, bot_patch['transform'], companion,
                                    aliases=BOT_ALIASES, companion_paths=bot_patch['COMPANIONS'], selected_only=True)
    print('OFFICIAL_RUNTIME_HOST_SOURCE_VERIFIED ' + json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
