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
COMPANIONS = {
    **{'packages/plugin/src/' + name: name for name in [
        'quenderin-host-policy.mjs', 'quenderin-host-policy.d.mts',
        'quenderin-bot-read-policy.mjs', 'quenderin-bot-read-policy.d.mts',
        'quenderin-bot-runtime.mjs', 'quenderin-bot-runtime.d.mts']},
    **{'packages/protocol/src/' + name: name for name in [
        'quenderin-bot-read-wire.mjs', 'quenderin-bot-read-wire.d.mts']},
}


def once(source, before, after):
    if source.count(before) != 1:
        raise ValueError('Pinned Host source seam changed')
    return source.replace(before, after, 1)


def transform(path, source):
    if path == 'packages/plugin/src/index.ts':
        source = "import { botSessionWritable } from './quenderin-bot-runtime.mjs'\n" + source
        source = once(source, "        peer,\n      ),\n    )", "        peer,\n      ),\n      sessionId => botSessionWritable(ctx.get('connection'), sessionId),\n    )")
    elif path == 'packages/protocol/src/index.ts':
        source = "import { assertBotReadWireBytes } from './quenderin-bot-read-wire.mjs'\n" + source
        source = once(source, '  return parseRemoteMessage(JSON.parse(text))',
            '  assertBotReadWireBytes(text)\n  return parseRemoteMessage(JSON.parse(text))')
    elif path.endswith('plugin-route-bridge.ts'):
        source = "import { BOT_READ_LIMITS, validateBotReadRequest, validateBotReadResponse } from './quenderin-bot-read-policy.mjs'\n" + source
        start = source.index('export const BOT_REMOTE_OPERATIONS = [')
        stop = source.index('] as const', start) + len('] as const')
        source = source[:start] + "export const BOT_REMOTE_OPERATIONS = ['quenderin-roster'] as const" + source[stop:]
        source = once(source, 'export type PluginRouteDispatcher = (',
            'export type PluginRouteDispatcher = ((')
        source = once(source, ') => Promise<{ status: number; json: unknown }>',
            ') => Promise<{ status: number; json: unknown }>) & { quenderinBotReadAvailable?: () => boolean }')
        start = source.index('    payload: z.record(')
        stop = source.index('\n}).strict()', start)
        source = source[:start] + "    payload: z.object({ schemaVersion: z.literal(1), workspaceId: z.string().min(1) }).strict(),\n  }).strict()," + source[stop:]
        source = once(source, '    if (serializedBytes(params) > MAX_SECURE_MESSAGE_BYTES) {',
            "    if (!validateBotReadRequest(params, (params.body.payload as { workspaceId: string }).workspaceId).ok\n      || serializedBytes(params) > BOT_READ_LIMITS.requestUTF8Bytes) {")
        source = once(source, '    if (serializedBytes(result) > MAX_SECURE_MESSAGE_BYTES) {',
            '    if (serializedBytes(result) > BOT_READ_LIMITS.resultUTF8Bytes) {')
        source = once(source, '    return { status: result.status, json: result.json }',
            "    if (result.status === 200 && !validateBotReadResponse(result, (params.body.payload as { workspaceId: string }).workspaceId).ok) {\n"
            "      throw new RpcError('INVALID_MESSAGE', 'Bot roster read unavailable')\n    }\n"
            "    if (result.status !== 200) return { status: 503, json: { ok: false, error: { code: 'BOT_READ_UNAVAILABLE', message: 'Bot roster read unavailable' } } }\n"
            '    return { status: result.status, json: result.json }')
    elif path.endswith('plugin-route-dispatcher.ts'):
        source = "import { mountedBotRead, botReadUnavailable } from './quenderin-bot-runtime.mjs'\n" + source
        source = once(source, '): PluginRouteDispatcher {\n  let cookie: string | undefined',
            "): PluginRouteDispatcher | undefined {\n  if (readConnection() === undefined) return undefined")
        source = once(source, '  return async (route, body, signal) => {',
            '  const dispatch: PluginRouteDispatcher = async (route, body, signal) => {')
        source = once(source, '    const handler = connection?.createSharedFetchHandler?.(\'/api\')',
            "    const mounted = mountedBotRead(connection)\n    if (!mounted) return botReadUnavailable()\n    const handler = connection?.createSharedFetchHandler?.('/api')")
        start = source.index('    } else {\n      const port = readPort()')
        stop = source.index('    const text = await response.text()', start)
        source = source[:start] + '    } else {\n      return botReadUnavailable()\n    }\n' + source[stop:]
        source = once(source, '    const text = await response.text()',
            "    const text = await response.text()\n    if (mountedBotRead(connection) !== mounted || new TextEncoder().encode(text).byteLength > 262144) return botReadUnavailable()")
        source = once(source, '    return { status: response.status, json }\n  }\n}',
            "    return { status: response.status, json }\n  }\n"
            "  dispatch.quenderinBotReadAvailable = () => {\n"
            "    const connection = readConnection()\n"
            "    return mountedBotRead(connection) !== undefined && typeof connection?.createSharedFetchHandler === 'function'\n"
            "  }\n  return dispatch\n}")
    elif path.endswith('server-connection.ts'):
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
            "      const nativeMethods = ['harness.transport.describe', 'harness.remote.call', 'harness.remote.stream.open', 'harness.remote.stream.close', 'plugin.route.call']\n"
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
            '    private readonly codexWorkspace?: CodexWorkspaceBridge,\n    private readonly quenderin?: QuenderinApprovalPolicy,\n    private readonly quenderinSessionWritable?: (sessionId: unknown) => boolean,')
        source = once(source, '    const params = callSchema.parse(input) as HarnessRemoteCallParams\n    this.assertAllowed(params.endpoint)',
            "    const params = callSchema.parse(input) as HarnessRemoteCallParams\n"
            "    if (params.endpoint === APPROVAL_ENDPOINT) {\n"
            "      if (!this.quenderin) throw new RpcError('PERMISSION_DENIED', 'Bound approvals are unavailable.')\n"
            "      const approved = this.quenderin.consume(requestArgs(params.payload))\n"
            "      return this.gateway.dispatch('$events/result', approved, AbortSignal.timeout(60_000))\n    }\n"
            "    if (params.endpoint === '$events/result') throw new RpcError('PERMISSION_DENIED', 'Use a bound approval response.')\n"
            "    if (!['session/list', 'session/create', 'session/page', 'session/prompt', 'session/cancel', 'session/modelCatalog', 'session/selectModel'].includes(params.endpoint)) {\n"
            "      throw new RpcError('METHOD_NOT_ALLOWED', 'This Host is configured for native Quenderin sessions.')\n    }\n"
            "    this.assertQuenderinWrite(params.endpoint, params.payload)\n"
            "    this.assertAllowed(params.endpoint)")
        source = once(source, '        codexResult = await this.codexWorkspace.call(',
            '        this.assertQuenderinWrite(params.endpoint, params.payload)\n        codexResult = await this.codexWorkspace.call(')
        source = once(source, '      const nativePayload = normalizeWorkspaceRequestPayload(',
            '      this.assertQuenderinWrite(params.endpoint, params.payload)\n      const nativePayload = normalizeWorkspaceRequestPayload(')
        source = once(source, '  private async directoryList(',
            "  private assertQuenderinWrite(endpoint: string, payload: unknown): void {\n"
            "    if (['session/prompt', 'session/selectModel'].includes(endpoint)\n"
            "      && this.quenderinSessionWritable?.(requestArgs(payload).sessionId) === false) {\n"
            "      throw new RpcError('PERMISSION_DENIED', 'This Bot session is read-only on Quenderin.')\n    }\n  }\n\n"
            '  private async directoryList(')
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
            '              this.terminalSpawner,\n            ),\n            new QuenderinApprovalPolicy(this.currentIdentity().deviceId, context.peerDeviceId),\n            this.quenderinSessionWritable,\n          )')
        source = once(source, '    private readonly pluginRoutes?: (peer?: unknown) => PluginRouteDispatcher | undefined,',
            '    private readonly pluginRoutes?: (peer?: unknown) => PluginRouteDispatcher | undefined,\n    private readonly quenderinSessionWritable?: (sessionId: unknown) => boolean,')
        source = once(source, "        'harness.remote.transfer.v1',\n      )",
            "        'harness.remote.transfer.v1',\n        APPROVAL_CAPABILITY,\n      )")
        source = once(source, '      fingerprint: this.identity.fingerprint,',
            "      fingerprint: this.identity.fingerprint,\n"
            "      pairingFingerprintSHA256: createHash('sha256').update(Buffer.from(this.identity.publicKey, 'base64url')).digest('hex'),")
        source = once(source, "    if (this.pluginRoutes?.() !== undefined) capabilities.push('plugin.route.v1')",
            "    if (this.pluginRoutes?.()?.quenderinBotReadAvailable?.() === true) capabilities.push('plugin.route.v1', 'quenderin.bot.read.v1')")
    else:
        raise ValueError('Unknown pinned source path')
    return source


def patch_for(checkout):
    manifest = json.loads((ROOT / 'upstream.json').read_text())
    patch = []
    for path, digest in manifest['files'].items():
        file = checkout / path
        current = file
        while current != checkout:
            if current.is_symlink():
                raise ValueError('Pinned Host source is linked')
            current = current.parent
        if file.is_symlink() or not file.is_file():
            raise ValueError('Pinned Host source is missing or linked')
        raw = file.read_bytes()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('Pinned Host source hash differs; no files changed')
        original = raw.decode('utf-8')
        changed = transform(path, original)
        patch.extend(difflib.unified_diff(original.splitlines(True), changed.splitlines(True), fromfile='a/' + path, tofile='b/' + path))
    for path, name in COMPANIONS.items():
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
    if args.checkout.is_symlink():
        raise ValueError('Linked Host checkout is forbidden')
    checkout = args.checkout.resolve(strict=True)
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != UPSTREAM:
        raise ValueError('Host checkout is not the supported upstream revision')
    if subprocess.run(['git', '-C', str(checkout), 'diff', '--quiet', 'HEAD', '--']).returncode != 0:
        raise ValueError('Host checkout is dirty')
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
