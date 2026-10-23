#!/usr/bin/env python3
"""Apply Quenderin's narrowly pinned MIT Host integration to an existing source checkout.

No downloads, installations, credentials, processes or provider calls. Check is default.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = '9a60e783ec1ceaff6116b0462a2863f07f602a55'


def once(source, before, after):
    if source.count(before) != 1:
        raise ValueError('Pinned Host source seam changed')
    return source.replace(before, after, 1)


def transform(path, source):
    if path.endswith('server-connection.ts'):
        source = "import { assertPeerAllowed } from './quenderin-host-policy.mjs'\n" + source
        source = once(source, '    const existing = this.identities.trustedPeer(descriptor.deviceId)',
            "    try { assertPeerAllowed(descriptor.deviceId, descriptor.identityKey) } catch {\n"
            "      this.sendControl('connect.rejected', { connectionId: payload.connectionId })\n"
            "      return\n    }\n    const existing = this.identities.trustedPeer(descriptor.deviceId)")
    elif path.endswith('connection-controller.ts'):
        source = "import { assertPeerAllowed } from './quenderin-host-policy.mjs'\n" + source
        source = once(source, '    const connectionId = channel.security.connectionId',
            "    try { assertPeerAllowed(channel.peerDeviceId, channel.peerIdentityKey) } catch {\n"
            "      await channel.close('DEVICE_REVOKED')\n"
            "      throw new ConnectionRejectedError('DEVICE_REVOKED', 'Host pairing confirmation is required.')\n"
            "    }\n    const connectionId = channel.security.connectionId")
        source = once(source, '      connection.unsubscribe = channel.onMessage(message => { void this.handle(connection, message) })',
            "      const stopMessages = channel.onMessage(message => { void this.handle(connection, message) })\n"
            "      const trustTimer = setInterval(() => {\n"
            "        try { assertPeerAllowed(channel.peerDeviceId, channel.peerIdentityKey) } catch {\n"
            "          void this.disconnect(connection, 'DEVICE_REVOKED').catch(() => undefined)\n"
            "        }\n      }, 2000)\n      trustTimer.unref()\n"
            "      connection.unsubscribe = () => { clearInterval(trustTimer); stopMessages() }")
        source = once(source, '      const response = await connection.router.handle(message)',
            "      assertPeerAllowed(connection.channel.peerDeviceId, connection.channel.peerIdentityKey)\n"
            "      const nativeMethods = ['harness.transport.describe', 'harness.remote.call', 'harness.remote.stream.open', 'harness.remote.stream.close']\n"
            "      const method = (message.payload as { method?: unknown } | undefined)?.method\n"
            "      if (message.type === 'rpc.request' && !nativeMethods.includes(String(method))) {\n"
            "        await this.sendConnection(connection, createRpcError(message.id, 'METHOD_NOT_ALLOWED', 'This Host is configured for native Quenderin sessions.'))\n"
            "        return\n      }\n"
            "      const response = await connection.router.handle(message)")
        source = once(source, '    await connection.channel.send(message)',
            "    assertPeerAllowed(connection.channel.peerDeviceId, connection.channel.peerIdentityKey)\n"
            "    await connection.channel.send(message)")
        source = once(source, '      await connection.channel.send(outbound)',
            '      await this.sendConnection(connection, outbound)')
    elif path.endswith('harness-remote-bridge.ts'):
        source = "import { APPROVAL_ENDPOINT, type QuenderinApprovalPolicy } from './quenderin-host-policy.mjs'\n" + source
        source = once(source, 'interface ActiveRemoteStream {\n  controller: AbortController',
            'interface ActiveRemoteStream {\n  endpoint: string\n  controller: AbortController')
        source = once(source, '    private readonly codexWorkspace?: CodexWorkspaceBridge,',
            '    private readonly codexWorkspace?: CodexWorkspaceBridge,\n    private readonly quenderin?: QuenderinApprovalPolicy,')
        source = once(source, '    const params = callSchema.parse(input) as HarnessRemoteCallParams\n    this.assertAllowed(params.endpoint)',
            "    const params = callSchema.parse(input) as HarnessRemoteCallParams\n"
            "    if (params.endpoint === APPROVAL_ENDPOINT) {\n"
            "      if (!this.quenderin) throw new RpcError('PERMISSION_DENIED', 'Bound approvals are unavailable.')\n"
            "      const approved = this.quenderin.consume(requestArgs(params.payload))\n"
            "      return this.gateway.dispatch('$events/result', approved, AbortSignal.timeout(60_000))\n    }\n"
            "    if (params.endpoint === '$events/result') throw new RpcError('PERMISSION_DENIED', 'Use a bound approval response.')\n"
            "    if (!['session/list', 'session/create', 'session/page', 'session/prompt', 'session/cancel', 'session/modelCatalog', 'session/selectModel'].includes(params.endpoint)) {\n"
            "      throw new RpcError('METHOD_NOT_ALLOWED', 'This Host is configured for native Quenderin sessions.')\n    }\n"
            "    this.assertAllowed(params.endpoint)")
        source = once(source, '    const params = streamOpenSchema.parse(input) as HarnessRemoteStreamOpenParams\n    this.assertAllowed(params.endpoint)',
            "    const params = streamOpenSchema.parse(input) as HarnessRemoteStreamOpenParams\n"
            "    if (!['workspace/follow', 'session/follow', 'session/control', '$events'].includes(params.endpoint)) {\n"
            "      throw new RpcError('METHOD_NOT_ALLOWED', 'This Host is configured for native Quenderin sessions.')\n    }\n"
            "    this.assertAllowed(params.endpoint)")
        source = once(source, '    this.streams.set(params.streamId, { controller })',
            '    this.streams.set(params.streamId, { controller, endpoint: params.endpoint })')
        source = once(source, "    void this.pump(params.streamId, source, controller.signal, params.endpoint === 'session/follow')",
            "    void this.pump(params.streamId, source, controller.signal, params.endpoint === 'session/follow', params.endpoint, params.payload)")
        source = once(source, "      active.controller.abort('client-closed')",
            "      this.quenderin?.streamClosed(active.endpoint)\n      active.controller.abort('client-closed')")
        source = once(source, "    const streams = [...this.streams.entries()]\n    this.streams.clear()",
            "    this.quenderin?.close()\n    const streams = [...this.streams.entries()]\n    this.streams.clear()")
        source = once(source, 'signal: AbortSignal, historyFollow = false): Promise<void> {',
            "signal: AbortSignal, historyFollow = false, endpoint = '', payload: unknown = {}): Promise<void> {")
        source = once(source, '        const frame: HarnessRemoteFrameData = {',
            '        const observed = this.quenderin?.observe(endpoint, payload, value) ?? value\n        const frame: HarnessRemoteFrameData = {')
        source = once(source, "...(value === undefined ? {} : { value: historyFollow && this.compactHistoryEnabled && isCompactSnapshot(value) ? compactHistory(value) : value }),",
            "...(observed === undefined ? {} : { value: historyFollow && this.compactHistoryEnabled && isCompactSnapshot(observed) ? compactHistory(observed) : observed }),")
        source = once(source, '      this.streams.delete(streamId)\n      await this.publish',
            '      this.quenderin?.streamClosed(endpoint)\n      this.streams.delete(streamId)\n      await this.publish')
    elif path.endswith('service.ts'):
        source = "import { createHash } from 'node:crypto'\nimport { APPROVAL_CAPABILITY, QuenderinApprovalPolicy } from './quenderin-host-policy.mjs'\n" + source
        source = once(source, '              this.terminalSpawner,\n            ),\n          )',
            '              this.terminalSpawner,\n            ),\n            new QuenderinApprovalPolicy(this.currentIdentity().deviceId, context.peerDeviceId),\n          )')
        source = once(source, "        'harness.remote.transfer.v1',\n      )",
            "        'harness.remote.transfer.v1',\n        APPROVAL_CAPABILITY,\n      )")
        source = once(source, '      fingerprint: this.identity.fingerprint,',
            "      fingerprint: this.identity.fingerprint,\n"
            "      pairingFingerprintSHA256: createHash('sha256').update(Buffer.from(this.identity.publicKey, 'base64url')).digest('hex'),")
    else:
        raise ValueError('Unknown pinned source path')
    return source


def patch_for(checkout):
    manifest = json.loads((ROOT / 'upstream.json').read_text())
    patch = []
    for path, digest in manifest['files'].items():
        file = checkout / path
        if file.is_symlink() or not file.is_file():
            raise ValueError('Pinned Host source is missing or linked')
        raw = file.read_bytes()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('Pinned Host source hash differs; no files changed')
        original = raw.decode('utf-8')
        changed = transform(path, original)
        patch.extend(difflib.unified_diff(original.splitlines(True), changed.splitlines(True), fromfile='a/' + path, tofile='b/' + path))
    for name in ['quenderin-host-policy.mjs', 'quenderin-host-policy.d.mts']:
        path = 'packages/plugin/src/' + name
        if (checkout / path).exists() or (checkout / path).is_symlink():
            raise ValueError('Companion destination already exists; no files changed')
        source = (ROOT / name).read_text()
        patch.extend(difflib.unified_diff([], source.splitlines(True), fromfile='/dev/null', tofile='b/' + path))
    return ''.join(patch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('--apply', action='store_true', help='Edit the four verified source files and add the two companion source files')
    args = parser.parse_args()
    checkout = args.checkout.resolve(strict=True)
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != UPSTREAM:
        raise ValueError('Host checkout is not the supported upstream revision')
    patch = patch_for(checkout)
    command = ['git', '-C', str(checkout), 'apply']
    subprocess.run(command + ['--check', '-'], input=patch, text=True, check=True)
    if args.apply:
        subprocess.run(command + ['-'], input=patch, text=True, check=True)
    print('QUENDERIN_HOST_' + ('SOURCE_PATCHED' if args.apply else 'PATCH_CHECK_PASS'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        print('Quenderin Host preparation failed; inspect the pinned checkout and public trust configuration.', file=sys.stderr)
        sys.exit(1)
