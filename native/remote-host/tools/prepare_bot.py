#!/usr/bin/env python3
"""Patch the exact existing, user-operated DS Bot channel; never start DS Bot."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = '1bebe826f74e9a72cabafd3b80602b05af867b38'
COMPANIONS = {'ds-bot/src/host/' + name: name for name in [
    'quenderin-bot-read-policy.mjs', 'quenderin-bot-read-policy.d.mts',
    'quenderin-bot-runtime.mjs', 'quenderin-bot-runtime.d.mts']}


def once(source, before, after):
    if source.count(before) != 1:
        raise ValueError('Pinned Bot source seam changed')
    return source.replace(before, after, 1)


def transform(path, source):
    if path == 'ds-bot/src/host/channel.js':
        source = "import { mountBotRead } from './quenderin-bot-runtime.mjs'\n" + source
        source = once(source, '  const { ctx, state } = rt',
            '  const { ctx, state } = rt\n  const quenderinBotRead = mountBotRead(rt)')
        source = once(source, "      const result = await handle(String(body?.endpoint ?? ''), body?.payload, request.signal)",
            "      // Branch before handle(): ordinary endpoints refresh/load/bootstrap.\n"
            "      const roster = body?.endpoint === 'quenderin-roster'\n"
            "        ? quenderinBotRead({ route: 'api/bot', body }) : undefined\n"
            "      const result = roster?.json ?? await handle(String(body?.endpoint ?? ''), body?.payload, request.signal)")
        source = once(source, "return new Response(JSON.stringify(result), { status: 200, headers:",
            "return new Response(JSON.stringify(result), { status: roster?.status ?? 200, headers:")
    elif path == 'ds-bot/src/host/store.js':
        source = once(source, '  let loaded = null', '  let loaded = null\n  let quenderinReady = false')
        source = once(source, '    for (const room of stale) void rt.retitleRoom(room)\n  })()',
            '    for (const room of stale) void rt.retitleRoom(room)\n  })().then(() => { quenderinReady = true })')
        source = once(source, '    state, load, save, refresh, readOnly, own,',
            '    state, load, save, refresh, readOnly, own,\n'
            '    // Cached publication only: this accessor never refreshes or checks the filesystem.\n'
            '    quenderinReadStatus: () => ({ ready: quenderinReady && !stopped && !lockBroken && stuck === undefined, readOnly: holder !== undefined }),')
    return source


def patch_for(checkout):
    manifest = json.loads((ROOT / 'bot-upstream.json').read_text())
    patch = []
    for path, digest in manifest['files'].items():
        file = checkout / path
        current = file
        while current != checkout:
            if current.is_symlink():
                raise ValueError('Linked Bot source is forbidden')
            current = current.parent
        raw = file.read_bytes()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('Pinned Bot source hash differs; no files changed')
        original = raw.decode('utf-8')
        changed = transform(path, original)
        patch.extend(difflib.unified_diff(original.splitlines(True), changed.splitlines(True), fromfile='a/' + path, tofile='b/' + path))
    for path, name in COMPANIONS.items():
        if (checkout / path).exists() or (checkout / path).is_symlink():
            raise ValueError('Bot companion destination already exists')
        source = (ROOT / name).read_text()
        patch.extend(difflib.unified_diff([], source.splitlines(True), fromfile='/dev/null', tofile='b/' + path))
    return ''.join(patch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.checkout.is_symlink():
        raise ValueError('Linked Bot checkout is forbidden')
    checkout = args.checkout.resolve(strict=True)
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != UPSTREAM or subprocess.run(['git', '-C', str(checkout), 'diff', '--quiet', 'HEAD', '--']).returncode != 0:
        raise ValueError('Exact clean Bot checkout required')
    patch = patch_for(checkout)
    command = ['git', '-C', str(checkout), 'apply']
    subprocess.run(command + ['--check', '-'], input=patch, text=True, check=True)
    if args.apply:
        subprocess.run(command + ['-'], input=patch, text=True, check=True)
    print('QUENDERIN_BOT_' + ('SOURCE_PATCHED' if args.apply else 'PATCH_CHECK_PASS'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        print('Quenderin Bot preparation failed; inspect the pinned public source checkout.', file=sys.stderr)
        sys.exit(1)
