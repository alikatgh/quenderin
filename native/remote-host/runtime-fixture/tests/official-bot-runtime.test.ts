// Runs the actual pinned Bot store/channel, Remote controller/router/Fetch bridge,
// and official Harness registries. Full Bot createRuntime startup is not invoked.
import { expect, it } from 'vitest';
import { Context } from '@deepseek-ai/cordis';
import { mountAgentLoopTestDependencies, mountAgentLoopTestHarness } from '@deepseek-ai/dsh-agent-loop-testkit';
import Gateway from '@deepseek-ai/dsh-api-gateway';
import RemoteAccess from '@deepseek-ai/dsh-api-remote-access';
import * as ApiRemotes from '@deepseek-ai/dsh-api-remotes';
import SessionController from '@deepseek-ai/dsh-api-session-controller';
import { TYPERT as SESSION } from '@deepseek-ai/dsh-api-session-controller/typert';
import WorkspaceController from '@deepseek-ai/dsh-api-workspace-controller';
import { TYPERT as WORKSPACE } from '@deepseek-ai/dsh-api-workspace-controller/typert';
import TypertRegistry from '@deepseek-ai/dsh-typert-registry';
import DefaultModel from '@deepseek-ai/dsh-agent-default-model';
import { HostConnectionService } from '@deepseek-ai/dsh-client-connection';
import FileUploads from '@deepseek-ai/dsh-client-file-upload';
import { AttachmentStore, type ImageAttachmentLimits } from '@deepseek-ai/dsh-attachment';
import { SessionQueryEngine } from '@deepseek-ai/dsh-session-query';
import { LlmAdapter, type GenerateOptions, type StreamChunk } from '@deepseek-ai/dsh-llm';
import * as Persistence from '@deepseek-ai/dsh-session-persistence-jsonl';
import Storage from '@deepseek-ai/dsh-storage';
import * as JsonStorage from '@deepseek-ai/dsh-storage-json';
import * as StorageDomain from '@deepseek-ai/dsh-storage-domain';
import WorkspaceRegistry from '@deepseek-ai/dsh-workspace';
import { SessionId } from '@deepseek-ai/dsh-session';
import { HarnessRemoteBridge } from '@quenderin/patched-host-bridge';
import { TypertGatewaySwitch } from '@quenderin/upstream-gateway-switch';
import { ConnectionController } from '@quenderin/connection-controller';
import { RpcRouter } from '@quenderin/rpc-router';
import { PluginRouteBridge } from '@quenderin/plugin-route-bridge';
import { createPluginRouteDispatcher } from '@quenderin/plugin-route-dispatcher';
import { mountedBotRead, botSessionWritable } from '@quenderin/bot-runtime';
import { install as installStore } from '@quenderin/pinned-bot-store';
import { install as installChannel } from '@quenderin/pinned-bot-channel';
import { decodeMessage, type RemoteMessage } from '@dsh-remote/protocol';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

class ZeroCallAdapter extends LlmAdapter {
  calls = 0;
  async resolveModel(provider: string, model: string) { return { provider, id: model, name: model }; }
  async *stream(_options: GenerateOptions): AsyncIterable<StreamChunk> { this.calls++; throw new Error('Zero model-call read budget exceeded'); }
}
class NoMediaAttachments extends AttachmentStore {
  readonly imageLimits: ImageAttachmentLimits = { maxImageBytes: 1, maxImagesPerMessage: 1, maxMessageImageBytes: 1, maxImagePixels: 1, maxImageDimension: 1, mediaTypes: [] };
  async validateImage(): Promise<never> { throw new Error('Media outside this fixture'); }
  async saveImage(): Promise<never> { throw new Error('Media outside this fixture'); }
  async readImage(): Promise<never> { throw new Error('Media outside this fixture'); }
}
class NoSearchQuery extends SessionQueryEngine {
  async searchSessions(): Promise<never> { throw new Error('Search outside this fixture'); }
  async searchEvents(): Promise<never> { throw new Error('Search outside this fixture'); }
}
async function until(predicate: () => boolean) {
  const deadline = performance.now() + 1500;
  while (!predicate()) { if (performance.now() >= deadline) throw new Error('Bot runtime condition timed out'); await new Promise(done => setTimeout(done, 1)); }
}
function files(root: string, prefix = ''): Record<string, string> {
  const entries: Record<string, string> = {};
  for (const name of readdirSync(join(root, prefix)).sort()) {
    const relative = join(prefix, name), path = join(root, relative);
    if (statSync(path).isDirectory()) Object.assign(entries, files(root, relative));
    else entries[relative] = createHash('sha256').update(readFileSync(path)).digest('hex');
  }
  return entries;
}

it('reads the pinned Bot roster via an admitted Remote Peer and the official shared Fetch carrier with zero read effects', async () => {
  const fixture = process.env.QUENDERIN_FIXTURE_ROOT;
  if (!fixture?.startsWith('/')) throw new Error('Isolated fixture root required');
  const root = join(fixture, 'bot-fixture'); mkdirSync(root);
  const ctx = new Context(), adapter = new ZeroCallAdapter();
  const publicKey = Buffer.alloc(32, 3).toString('base64url');
  const trustPath = join(root, 'public-trust.json');
  const previousTrust = process.env.QUENDERIN_REMOTE_TRUST_FILE;
  process.env.QUENDERIN_REMOTE_TRUST_FILE = trustPath;
  const trust = (allowed: boolean) => writeFileSync(trustPath, JSON.stringify({ version: 1, peers: allowed ? [{ deviceId: 'fixture-native', publicKey }] : [] }), { mode: 0o600 });
  trust(true);
  let controller: ConnectionController | undefined, harness: HarnessRemoteBridge | undefined;
  let completed: any;
  try {
    await ctx.plugin(TypertRegistry); await ctx.plugin(RemoteAccess);
    await mountAgentLoopTestDependencies(ctx, { workingDirectory: true });
    await ctx.plugin(Storage); await ctx.plugin(JsonStorage, { root: join(root, 'domain-json') });
    await ctx.plugin(StorageDomain, { backend: 'json' });
    await ctx.plugin(Persistence, { root: join(root, 'sessions'), compression: 'none', listConcurrency: 1 });
    await ctx.plugin(WorkspaceRegistry); await mountAgentLoopTestHarness(ctx);
    await ctx.plugin(DefaultModel, { provider: 'fixture', model: 'scripted' });
    ctx.llm.registerAdapter(['fixture'], adapter);
    new NoMediaAttachments(ctx); new NoSearchQuery(ctx);
    const noBrowserAuth = new Proxy({}, { get() { throw new Error('Browser authentication outside this fixture'); } });
    new HostConnectionService(ctx, [], noBrowserAuth as never);
    await ctx.plugin(FileUploads);
    ctx.effect(() => ctx.typert.register(SESSION)); ctx.effect(() => ctx.typert.register(WORKSPACE));
    await ctx.plugin(SessionController, { nativeOpen: false });
    await ctx.plugin(WorkspaceController, { documentsDirectory: root });
    await ctx.plugin(Gateway, { streamInboxBytes: 65_536 }); await ctx.plugin(ApiRemotes);
    const peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' });
    const local = new TypertGatewaySwitch(ctx.typertGateway).local(peer);
    harness = new HarnessRemoteBridge(local, async () => undefined, undefined, '0.2.1-rc.1', undefined, undefined, undefined,
      sessionId => botSessionWritable(ctx.connection, sessionId));
    const capabilities = () => ['harness.remote.v3', 'harness.remote.transfer.v1', ...(createPluginRouteDispatcher(() => ctx.connection, () => undefined)?.quenderinBotReadAvailable?.() === true ? ['plugin.route.v1', 'quenderin.bot.read.v1'] : [])];
    let routersCreated = 0;
    let deferred: (() => void) | undefined, hold = false, dispatchCompleted = false;
    controller = new ConnectionController({ isTrusted: (id: string, key: string) => id === 'fixture-native' && key === publicKey } as never,
      () => {
        routersCreated++;
        const dispatch = createPluginRouteDispatcher(() => ctx.connection, () => { throw new Error('Loopback fallback forbidden'); }, peer);
        const route = dispatch && new PluginRouteBridge(async (...args: any[]) => {
          const result = await dispatch(...args as [string, unknown, AbortSignal]);
          if (hold) { dispatchCompleted = true; await new Promise<void>(resolve => { deferred = resolve; }); }
          return result;
        });
        return new RpcRouter(undefined, 128, undefined, undefined, harness, capabilities, undefined, undefined, undefined, undefined, route);
      });
    let receive: ((message: RemoteMessage) => void) | undefined, closed = false, sequence = 0;
    const sent: RemoteMessage[] = [];
    const connect = async () => {
      closed = false;
      await controller!.accept({ security: { protocol: 'Noise_IK_25519_ChaChaPoly_SHA256', connectionId: `fixture-connection-${++sequence}`, membershipId: 'fixture-membership' },
        peerDeviceId: 'fixture-native', peerIdentityKey: publicKey,
        send: async message => { sent.push(message); },
        onMessage: handler => { receive = handler; return () => { receive = undefined; }; }, close: async () => { closed = true; } });
    };
    const invoke = async (method: string, params: any) => {
      const requestId = `bot-read-${++sequence}`, before = sent.length;
      receive!(decodeMessage(JSON.stringify({ v: 1, id: requestId, type: 'rpc.request', timestamp: 1, payload: { method, params } })));
      await until(() => sent.length > before || closed);
      if (closed) throw new Error('Unexpected fixture disconnect');
      return sent.at(-1)! as any;
    };
    await connect();
    expect((await invoke('harness.transport.describe', {})).payload.result.capabilities).not.toContain('quenderin.bot.read.v1');
    expect((await invoke('plugin.route.call', { route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: 'unavailable' } } })).payload.result.status).toBe(503);
    expect(adapter.calls).toBe(0);

    const path = join(root, 'workspace'); mkdirSync(path);
    const workspace = await ctx.workspaceRegistry.create(path, 'Synthetic Bot workspace');
    await ctx.sessionController.create({ workspaceId: workspace.id, sessionId: SessionId('fixture-bot') });
    await ctx.sessionController.create({ workspaceId: workspace.id, sessionId: SessionId('fixture-bot-part') });
    for (const sessionId of ['fixture-room', 'fixture-group-member', 'fixture-group-past']) {
      await ctx.sessionController.create({ workspaceId: workspace.id, sessionId: SessionId(sessionId) });
    }
    await until(() => workspace.sessionIds.includes(SessionId('fixture-bot-part')));
    const home = join(root, 'bot'); mkdirSync(home);
    writeFileSync(join(home, 'state.json'), JSON.stringify({ version: 1, workspaceId: workspace.id, revision: 7,
      mainBotIds: [], bots: { 'fixture-bot': { id: 'fixture-bot', name: 'Researcher', sessionId: 'fixture-bot-part', model: 'fixture/scripted', permission: 'read-only', capabilities: [], instructions: 'SYNTHETIC_PRIVATE_INSTRUCTIONS' } },
      rooms: { 'fixture-room': { id: 'fixture-room', name: 'Synthetic group', named: true, members: ['fixture-bot'], admin: null, mode: 'admin', notice: '',
        sessions: { 'fixture-bot': 'fixture-group-member' }, segments: { 'fixture-bot': [{ sessionId: 'fixture-group-past' }] } } },
      agents: {}, capabilities: { items: {} }, exchanges: [], exchangeTurns: {}, works: {}, questions: {}, views: {}, prefs: {}, switching: {} }));
    let rt: any, botFiber: any;
    await ctx.plugin({ name: 'fixture-user-operated-bot', async apply(botCtx: Context) {
      botFiber = botCtx.fiber;
      rt = { ctx: botCtx, home, statePath: join(home, 'state.json'), warn: () => undefined };
      installStore(rt);
      expect(rt.quenderinReadStatus().ready).toBe(false);
      await rt.load();
      expect(rt.quenderinReadStatus()).toEqual({ ready: true, readOnly: false });
      expect(rt.chatOwners.get('fixture-bot-part')).toBe('fixture-bot');
      installChannel(rt); await rt.load();
    } });
    const startupRevision = rt.state.revision;
    expect(mountedBotRead(ctx.connection)).toBeDefined();
    expect(routersCreated).toBe(1);
    const described = (await invoke('harness.transport.describe', {})).payload.result;
    expect(described.capabilities).toEqual(expect.arrayContaining(['plugin.route.v1', 'quenderin.bot.read.v1']));
    const readEffects: Record<string, number> = { modelCalls: 0, refreshCalls: 0, loadCalls: 0, bootstrapCalls: 0, secretReads: 0, agentStarts: 0, stateWrites: 0, catalogCalls: 0 };
    for (const [method, count] of [['refresh', 'refreshCalls'], ['load', 'loadCalls'], ['bootstrap', 'bootstrapCalls'], ['loadSecrets', 'secretReads'], ['resolveAgent', 'agentStarts'], ['save', 'stateWrites'], ['catalog', 'catalogCalls']]) {
      rt[method] = () => { readEffects[count]++; throw new Error('Forbidden read effect'); };
    }
    const before = files(root);
    const request = { route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: workspace.id } } };
    const reply = await invoke('plugin.route.call', request);
    expect(reply.type).toBe('rpc.response');
    const result = reply.payload.result;
    expect(result).toEqual({ status: 200, json: { ok: true, value: { schemaVersion: 1, workspaceId: workspace.id, revision: startupRevision, readOnly: false,
      bots: [{ id: 'fixture-bot', name: 'Researcher', sessionId: 'fixture-bot-part', model: 'fixture/scripted', permission: 'read-only' }] } } });
    expect(JSON.stringify(result)).not.toContain('PRIVATE');
    expect(files(root)).toEqual(before);
    const outcomes: Record<string, any> = {};
    const unavailable = async (name: string, params = request) => { const value = (await invoke('plugin.route.call', params)).payload.result; expect(value.status).toBe(503); outcomes[name] = value; };
    const readStatus = rt.quenderinReadStatus;
    rt.quenderinReadStatus = () => ({ ready: false, readOnly: false }); await unavailable('notReady'); rt.quenderinReadStatus = readStatus;
    await unavailable('wrongWorkspace', { ...request, body: { ...request.body, payload: { schemaVersion: 1, workspaceId: 'wrong-workspace' } } });
    rt.state.revision = startupRevision - 1; await unavailable('staleRevision'); rt.state.revision = startupRevision;
    rt.chatOwners.set('fixture-bot-part', 'other-bot'); await unavailable('wrongCurrentOwner'); rt.chatOwners.set('fixture-bot-part', 'fixture-bot');
    const otherPath = join(root, 'other-workspace'); mkdirSync(otherPath);
    const other = await ctx.workspaceRegistry.create(otherPath, 'Other workspace');
    await ctx.sessionController.create({ workspaceId: other.id, sessionId: SessionId('fixture-other-session') });
    const otherWorkspaceRequest = { ...request, body: { ...request.body, payload: { schemaVersion: 1, workspaceId: other.id } } };
    const otherWorkspaceReply = await invoke('plugin.route.call', otherWorkspaceRequest);
    expect(otherWorkspaceReply.type).toBe('rpc.response');
    const otherWorkspaceResult = otherWorkspaceReply.payload.result;
    expect(otherWorkspaceResult).toEqual({ status: 200, json: { ok: true, value: {
      schemaVersion: 1, workspaceId: other.id, revision: startupRevision, readOnly: false, bots: [],
    } } });
    expect(JSON.stringify(otherWorkspaceResult)).not.toContain('fixture-bot');
    expect(JSON.stringify(otherWorkspaceResult)).not.toContain(workspace.id);
    rt.state.bots['fixture-bot'].sessionId = 'fixture-other-session'; rt.chatOwners.set('fixture-other-session', 'fixture-bot');
    await unavailable('wrongSessionWorkspace'); await unavailable('invalidTeamOwnershipForOtherWorkspace', otherWorkspaceRequest);
    rt.state.bots['fixture-bot'].sessionId = 'fixture-bot-part'; rt.chatOwners.delete('fixture-other-session');
    for (const endpoint of ['state', 'send', 'approval-answer', 'install', 'update-install']) {
      const denied = await invoke('plugin.route.call', { ...request, body: { ...request.body, endpoint } });
      expect(denied.type).toBe('rpc.error'); expect(denied.payload.code).toBe('INVALID_MESSAGE');
    }
    for (const endpoint of ['session/prompt', 'session/selectModel']) {
      for (const sessionId of ['fixture-bot-part', 'fixture-room', 'fixture-group-member', 'fixture-group-past']) {
        const denied = await invoke('harness.remote.call', { endpoint, payload: { args: { request: { sessionId } } } });
        expect(denied.type).toBe('rpc.error'); expect(denied.payload.code).toBe('PERMISSION_DENIED');
      }
    }
    expect(botSessionWritable(ctx.connection, 'fixture-other-session')).toBe(true);
    const ordinaryModelSelection = await invoke('harness.remote.call', { endpoint: 'session/selectModel', payload: { args: { request: {
      sessionId: 'fixture-other-session', provider: 'fixture', model: 'scripted',
    } } } });
    expect(ordinaryModelSelection.type).toBe('rpc.response');
    expect(ordinaryModelSelection.payload.result).toMatchObject({ ok: true, value: { selected: { provider: 'fixture', model: 'scripted' } } });
    expect(adapter.calls).toBe(0); expect(Object.values(readEffects)).toEqual(Object.values(readEffects).map(() => 0));
    completed = { schema: 1, harnessRevision: '1600d8a1e140dcde43a1a0941940a0480712c011', remoteRevision: '9a60e783ec1ceaff6116b0462a2863f07f602a55', botRevision: '1bebe826f74e9a72cabafd3b80602b05af867b38',
      lifecycle: 'explicit synthetic store load, then real channel.install; full createRuntime not invoked', authenticatedCarrier: 'admitted ConnectionController channel -> RpcRouter -> shared Fetch with official owner Peer',
      workspaceId: workspace.id, request, rawResult: JSON.stringify(result), result, readEffects, outcomes,
      ordinaryWorkspace: { workspaceId: other.id, request: otherWorkspaceRequest, rawResult: JSON.stringify(otherWorkspaceResult), result: otherWorkspaceResult } };
    // Revoke while a successful real Fetch dispatch is awaiting publication.
    hold = true;
    receive!(decodeMessage(JSON.stringify({ v: 1, id: 'revoke-read', type: 'rpc.request', timestamp: 1, payload: { method: 'plugin.route.call', params: request } })));
    await until(() => dispatchCompleted);
    // Remove only the Bot plugin. This same admitted connection and router must
    // stop advertising and serving the read without reconnecting the Peer.
    const connection = ctx.connection;
    const staleDispatcher = createPluginRouteDispatcher(() => connection, () => undefined, peer)!;
    await botFiber.dispose();
    expect(mountedBotRead(connection)).toBeUndefined();
    expect((await invoke('harness.transport.describe', {})).payload.result.capabilities).not.toContain('quenderin.bot.read.v1');
    hold = false;
    await unavailable('unmounted');
    expect(routersCreated).toBe(1);
    expect((await staleDispatcher('api/bot', request.body, AbortSignal.timeout(1000))).status).toBe(503);
    completed.unmountedCapabilityAbsent = true;
    completed.sameRouterBeforeMountAfterMountAndUnmount = true;
    const beforeRevocation = sent.length;
    trust(false); deferred!(); await until(() => closed);
    expect(sent.length).toBe(beforeRevocation); completed.revocationDroppedResult = true;
    writeFileSync(join(fixture, 'bot-runtime-facts.json'), JSON.stringify(completed) + '\n', { flag: 'wx', mode: 0o600 });
  } finally {
    await controller?.close(); await harness?.closeAll(); await ctx.fiber.dispose();
    if (previousTrust === undefined) delete process.env.QUENDERIN_REMOTE_TRUST_FILE; else process.env.QUENDERIN_REMOTE_TRUST_FILE = previousTrust;
  }
});
