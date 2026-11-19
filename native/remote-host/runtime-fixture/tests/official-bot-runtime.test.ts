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
import Commands from '@deepseek-ai/dsh-commands';
import { SessionQueryEngine } from '@deepseek-ai/dsh-session-query';
import { LlmAdapter, type GenerateOptions, type StreamChunk } from '@deepseek-ai/dsh-llm';
import * as Persistence from '@deepseek-ai/dsh-session-persistence-jsonl';
import Storage from '@deepseek-ai/dsh-storage';
import * as JsonStorage from '@deepseek-ai/dsh-storage-json';
import * as StorageDomain from '@deepseek-ai/dsh-storage-domain';
import WorkspaceRegistry from '@deepseek-ai/dsh-workspace';
import Approval from '@deepseek-ai/dsh-user-approval';
import { SessionId } from '@deepseek-ai/dsh-session';
import { HarnessRemoteBridge } from '@quenderin/patched-host-bridge';
import { TypertGatewaySwitch } from '@quenderin/upstream-gateway-switch';
import { ConnectionController } from '@quenderin/connection-controller';
import { RpcRouter } from '@quenderin/rpc-router';
import { PluginRouteBridge } from '@quenderin/plugin-route-bridge';
import { createPluginRouteDispatcher } from '@quenderin/plugin-route-dispatcher';
import { createBotWorkScope, mountedBotWork } from '@quenderin/bot-work-runtime';
import { initializeBotWorkJournal, BotWorkJournal } from '@quenderin/bot-work-journal';
import { mountedBotRead, botSessionWritable } from '@quenderin/bot-runtime';
import { install as installStore } from '@quenderin/pinned-bot-store';
import { install as installChannel } from '@quenderin/pinned-bot-channel';
import { decodeMessage, type RemoteMessage } from '@dsh-remote/protocol';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { types } from 'node:util';

class ZeroCallAdapter extends LlmAdapter {
  calls = 0; workMode = false; waiting = false; aborted = false;
  async listModels(provider: string) { return [{ provider, id: 'scripted', name: 'scripted' }]; }
  async resolveModel(provider: string, model: string) { return { provider, id: model, name: model }; }
  async *stream(options: GenerateOptions): AsyncIterable<StreamChunk> {
    this.calls++;
    if (!this.workMode || this.calls > 2) throw new Error('Two-call synthetic Bot work budget exceeded');
    options.signal?.throwIfAborted();
    const text = 'Synthetic Bot work reply.';
    yield { type: 'block-start', index: 0, blockType: 'text' };
    yield { type: 'text-delta', index: 0, text };
    if (this.calls === 2) {
      const signal = options.signal;
      if (!signal) throw new Error('Official cancellation signal required');
      let abort!: () => void;
      try {
        this.waiting = true;
        await new Promise<void>(done => { abort = () => { this.aborted = true; done(); }; if (signal.aborted) abort(); else signal.addEventListener('abort', abort, { once: true }); });
      } finally { signal.removeEventListener('abort', abort); this.waiting = false; }
      signal.throwIfAborted();
    }
    yield { type: 'block-end', index: 0, block: { type: 'text', text } };
    yield { type: 'finish', reason: { kind: 'stop' } };
  }
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
  const previousJournal = process.env.QUENDERIN_BOT_WORK_JOURNAL;
  const journalPath = join(root, 'work-journal'); initializeBotWorkJournal(journalPath);
  process.env.QUENDERIN_BOT_WORK_JOURNAL = journalPath;
  process.env.QUENDERIN_REMOTE_TRUST_FILE = trustPath;
  const trust = (allowed: boolean) => writeFileSync(trustPath, JSON.stringify({ version: 1, peers: allowed ? [{ deviceId: 'fixture-native', publicKey }] : [] }), { mode: 0o600 });
  trust(true);
  let controller: ConnectionController | undefined, harness: HarnessRemoteBridge | undefined;
  let toolCalls = 0;
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
    expect(await ctx.llm.listModels('fixture'), 'Static synthetic model catalog').toEqual([{ provider: 'fixture', id: 'scripted', name: 'scripted' }]);
    new NoMediaAttachments(ctx); new NoSearchQuery(ctx);
    await ctx.plugin(Commands);
    const noBrowserAuth = new Proxy({}, { get() { throw new Error('Browser authentication outside this fixture'); } });
    new HostConnectionService(ctx, [], noBrowserAuth as never);
    await ctx.plugin(FileUploads);
    await ctx.plugin(Approval, { policy: 'ask' });
    ctx.on('tools/pre-execute', async () => {
      toolCalls++;
      throw new Error('Zero-tool Bot fixture budget exceeded');
    });
    ctx.effect(() => ctx.typert.register(SESSION)); ctx.effect(() => ctx.typert.register(WORKSPACE));
    await ctx.plugin(SessionController, { nativeOpen: false });
    await ctx.plugin(WorkspaceController, { documentsDirectory: root });
    for (const service of new Set(['commands', 'approval', ...SessionController.inject, ...WorkspaceController.inject, 'sessionController', 'workspaceController'])) {
      expect(ctx.get(service), `Required Bot fixture service "${service}" is inactive`).toBeDefined();
    }
    await ctx.plugin(Gateway, { streamInboxBytes: 65_536 }); await ctx.plugin(ApiRemotes);
    expect(ctx.get('typertGateway'), 'Required Bot fixture Gateway is inactive').toBeDefined();
    const peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' });
    const local = new TypertGatewaySwitch(ctx.typertGateway).local(peer);
    expect(local.supportsCarrier).toBe(true);
    harness = new HarnessRemoteBridge(local, async () => undefined, undefined, '0.2.1-rc.1', undefined, undefined, undefined,
      sessionId => botSessionWritable(ctx.connection, sessionId));
    const capabilities = () => ['harness.remote.v3', 'harness.remote.transfer.v1', ...(createPluginRouteDispatcher(() => ctx.connection, () => undefined)?.quenderinBotReadAvailable?.() === true ? ['plugin.route.v1', 'quenderin.bot.read.v1'] : []), ...(createPluginRouteDispatcher(() => ctx.connection, () => undefined)?.quenderinBotWorkAvailable?.() === true ? ['quenderin.bot.work.v1'] : [])];
    let routersCreated = 0;
    let deferred: (() => void) | undefined, hold = false, dispatchCompleted = false;
    controller = new ConnectionController({ isTrusted: (id: string, key: string) => id === 'fixture-native' && key === publicKey } as never,
      context => {
        routersCreated++;
        const workScope = createBotWorkScope('fixture-host', context.peerDeviceId, context.peerIdentityKey!, context.quenderinAssertAuthorized!);
        const dispatch = createPluginRouteDispatcher(() => ctx.connection, () => { throw new Error('Loopback fallback forbidden'); }, peer, workScope);
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
    const createSession = async (workspaceId: string, sessionId: string) => {
      const reply = await invoke('harness.remote.call', { endpoint: 'session/create', payload: { args: { request: {
        workspaceId, sessionId: SessionId(sessionId),
      } } } });
      expect(reply.type).toBe('rpc.response');
      expect(reply.payload.result).toEqual({ ok: true, value: { sessionId } });
      await until(() => ctx.workspaceRegistry.list().some(workspace => workspace.id === workspaceId && workspace.sessionIds.includes(SessionId(sessionId))));
    };
    await connect();
    expect((await invoke('harness.transport.describe', {})).payload.result.capabilities).not.toContain('quenderin.bot.read.v1');
    expect((await invoke('plugin.route.call', { route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: 'unavailable' } } })).payload.result.status).toBe(503);
    expect(adapter.calls).toBe(0);

    const path = join(root, 'workspace'); mkdirSync(path);
    const workspace = await ctx.workspaceRegistry.create(path, 'Synthetic Bot workspace');
    for (const sessionId of ['fixture-bot', 'fixture-bot-part', 'fixture-room', 'fixture-group-member', 'fixture-group-past']) {
      await createSession(workspace.id, sessionId);
    }
    const home = join(root, 'bot'); mkdirSync(home);
    writeFileSync(join(home, 'state.json'), JSON.stringify({ version: 1, workspaceId: workspace.id, revision: 7,
      mainBotIds: [], bots: { 'fixture-bot': { id: 'fixture-bot', name: 'Researcher', sessionId: 'fixture-bot-part', model: 'fixture/scripted', permission: 'read-only', capabilities: [], instructions: 'SYNTHETIC_PRIVATE_INSTRUCTIONS' } },
      rooms: { 'fixture-room': { id: 'fixture-room', name: 'Synthetic group', named: true, members: ['fixture-bot'], admin: null, mode: 'admin', notice: '',
        sessions: { 'fixture-bot': 'fixture-group-member' }, segments: { 'fixture-bot': [{ sessionId: 'fixture-group-past' }] } } },
      agents: {}, capabilities: { items: {} }, exchanges: [], exchangeTurns: {}, works: {}, questions: {}, views: {}, prefs: {}, switching: {} }));
    let rt: any, botFiber: any;
    await ctx.plugin({ name: 'fixture-user-operated-bot', inject: ['connection', 'workspaceRegistry', 'sessionController'], async apply(botCtx: Context) {
      botFiber = botCtx.fiber;
      rt = { ctx: botCtx, home, statePath: join(home, 'state.json'), warn: () => undefined };
      installStore(rt);
      expect(rt.quenderinReadStatus().ready).toBe(false);
      await rt.load();
      expect(rt.quenderinReadStatus()).toEqual({ ready: true, readOnly: false });
      expect(rt.chatOwners.get('fixture-bot-part')).toBe('fixture-bot');
      const botWorkspace = botCtx.workspaceRegistry.get(rt.state.workspaceId);
      expect(botWorkspace?.id, 'Bot plugin-scoped authoritative Workspace').toBe(workspace.id);
      expect(botWorkspace?.sessionIds, 'Bot plugin-scoped Workspace membership').toEqual(expect.arrayContaining([
        'fixture-bot', 'fixture-bot-part', 'fixture-room', 'fixture-group-member', 'fixture-group-past',
      ]));
      installChannel(rt); await rt.load();
    } });
    const startupRevision = rt.state.revision;
    expect(mountedBotRead(ctx.connection)).toBeDefined();
    expect(routersCreated).toBe(1);
    const described = (await invoke('harness.transport.describe', {})).payload.result;
    expect(described.capabilities).toEqual(expect.arrayContaining(['plugin.route.v1', 'quenderin.bot.read.v1']));
    const readEffects: Record<string, number> = { modelCalls: 0, refreshCalls: 0, loadCalls: 0, bootstrapCalls: 0, secretReads: 0, agentStarts: 0, stateWrites: 0, catalogCalls: 0 };
    const originalMethods: Record<string, any> = {};
    for (const [method, count] of [['refresh', 'refreshCalls'], ['load', 'loadCalls'], ['bootstrap', 'bootstrapCalls'], ['loadSecrets', 'secretReads'], ['resolveAgent', 'agentStarts'], ['save', 'stateWrites'], ['catalog', 'catalogCalls']]) {
      originalMethods[method] = rt[method];
      rt[method] = () => { readEffects[count]++; throw new Error('Forbidden read effect'); };
    }
    const before = files(root);
    const request = { route: 'api/bot', body: { endpoint: 'quenderin-roster', payload: { schemaVersion: 1, workspaceId: workspace.id } } };
    expect(rt.quenderinReadStatus(), 'Cached Bot readiness after channel mount').toEqual({ ready: true, readOnly: false });
    expect(rt.state.workspaceId, 'Loaded Bot workspace identity').toBe(workspace.id);
    expect(ctx.workspaceRegistry.get(workspace.id)?.sessionIds, 'Loaded Bot workspace membership').toEqual(expect.arrayContaining([
      'fixture-bot', 'fixture-bot-part', 'fixture-room', 'fixture-group-member', 'fixture-group-past',
    ]));
    const currentBot = rt.state.bots['fixture-bot'];
    expect(currentBot.id, 'Loaded Bot identity').toBe('fixture-bot');
    expect(currentBot.sessionId, 'Loaded Bot current part').toBe('fixture-bot-part');
    expect(rt.chatOwners.get(currentBot.sessionId), 'Loaded current-part ownership').toBe(currentBot.id);
    for (const owner of ['chatOwners', 'groupOwners', 'pastOwners']) {
      expect(types.isMap(rt[owner]), `Loaded ${owner} has native Map brand`).toBe(true);
      expect(types.isProxy(rt[owner]), `Loaded ${owner} is not a proxy`).toBe(false);
    }
    expect(currentBot.name, 'Loaded public Bot name').toBe('Researcher');
    expect(currentBot.model, 'Loaded public Bot model').toBe('fixture/scripted');
    expect(currentBot.permission, 'Loaded public Bot permission').toBe('read-only');
    const expectedRoster = { status: 200, json: { ok: true, value: { schemaVersion: 1, workspaceId: workspace.id, revision: startupRevision, readOnly: false,
      bots: [{ id: 'fixture-bot', name: 'Researcher', sessionId: 'fixture-bot-part', model: 'fixture/scripted', permission: 'read-only' }] } } };
    const cachedAdapter = mountedBotRead(ctx.connection)!;
    const cachedRoster = cachedAdapter.read(request);
    const diagnostic = cachedAdapter.readDiagnostic();
    const diagnosticCodes = Object.freeze(['binding', 'state', 'request', 'readiness', 'revision', 'workspace', 'membership', 'owners', 'bot-fields', 'projection', 'state-changed', 'ready']);
    expect(diagnosticCodes.includes(diagnostic), 'Cached roster diagnostic belongs to the fixed allowlist').toBe(true);
    expect(Object.values(readEffects), 'Direct cached roster read effects').toEqual(Object.values(readEffects).map(() => 0));
    expect(cachedRoster, `Direct mounted cached roster: ${diagnostic}`).toEqual(expectedRoster);
    const sharedFetch = ctx.connection.createSharedFetchHandler('/api');
    const fetchedRoster = await sharedFetch.fetch(new Request('http://127.0.0.1/api/bot', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(request.body), signal: AbortSignal.timeout(1000),
    }), peer);
    expect(Object.values(readEffects), 'Official shared Fetch roster read effects').toEqual(Object.values(readEffects).map(() => 0));
    expect({ status: fetchedRoster.status, json: await fetchedRoster.json() }, 'Official shared Fetch roster').toEqual(expectedRoster);
    const reply = await invoke('plugin.route.call', request);
    expect(reply.type).toBe('rpc.response');
    const result = reply.payload.result;
    expect(result, 'Admitted Remote roster').toEqual(expectedRoster);
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
    await createSession(other.id, 'fixture-other-session');
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
    expect(ordinaryModelSelection.payload.result.error?.code, 'Ordinary model-selection failure code').toBeUndefined();
    expect(ordinaryModelSelection.payload.result).toEqual({ ok: true, value: { selected: { provider: 'fixture', model: 'scripted' } } });
    expect(adapter.calls).toBe(0); expect(toolCalls).toBe(0); expect(Object.values(readEffects)).toEqual(Object.values(readEffects).map(() => 0));
    completed = { schema: 1, harnessRevision: '1600d8a1e140dcde43a1a0941940a0480712c011', remoteRevision: '9a60e783ec1ceaff6116b0462a2863f07f602a55', botRevision: '1bebe826f74e9a72cabafd3b80602b05af867b38',
      lifecycle: 'explicit synthetic store load, then real channel.install; full createRuntime not invoked', authenticatedCarrier: 'admitted ConnectionController channel -> RpcRouter -> shared Fetch with official owner Peer',
      workspaceId: workspace.id, request, rawResult: JSON.stringify(result), result, readEffects, outcomes,
      ordinaryWorkspace: { workspaceId: other.id, request: otherWorkspaceRequest, rawResult: JSON.stringify(otherWorkspaceResult), result: otherWorkspaceResult } };
    // Work begins only after the zero-effect read checks. The runtime and queue
    // are real; an empty synthetic capability preparer and two-call text adapter
    // replace credentials and install no Bot tools/providers or background jobs.
    for (const [method, original] of Object.entries(originalMethods)) rt[method] = original;
    let capabilityPreparations = 0;
    rt.ensureCapabilities = async () => { capabilityPreparations++; };
    adapter.workMode = true;
    const workEvents: { sessionId: string; type: string; data: any }[] = [];
    ctx.on('session/event', (session, event) => {
      if (session.id === 'fixture-bot-part' && ['user/message', 'turn/start', 'turn/end'].includes(event.type)) {
        if (workEvents.length >= 16) throw new Error('Synthetic Bot work event budget exceeded');
        workEvents.push({ sessionId: session.id, type: event.type, data: event.data });
      }
    });
    expect(mountedBotWork(ctx.connection)?.ready()).toBe(true);
    expect((await invoke('harness.transport.describe', {})).payload.result.capabilities).toContain('quenderin.bot.work.v1');
    const workScope = createBotWorkScope('fixture-host', 'fixture-native', publicKey, () => undefined);
    const journal = new BotWorkJournal(journalPath);
    const command = (commandId: string) => ({ route: 'api/bot', body: { endpoint: 'quenderin-submit', payload: {
      schemaVersion: 1, workspaceId: workspace.id, botId: 'fixture-bot', expectedSessionId: 'fixture-bot-part',
      expectedRevision: rt.state.revision, commandId, text: 'Complete the bounded synthetic Bot task.',
    } } });
    const firstCommand = command('fixture-work-first');
    const firstWork = (await invoke('plugin.route.call', firstCommand)).payload.result;
    expect(firstWork.json.value).toMatchObject({ state: 'accepted', sessionId: 'fixture-bot-part', revision: firstCommand.body.payload.expectedRevision, reason: null });
    const firstEntry = journal.lookup(workScope, firstCommand.body.payload)!;
    await until(() => workEvents.some(event => event.type === 'turn/end') && journal.lookup(workScope, firstCommand.body.payload)?.pending === false);
    expect(workEvents.filter(event => event.type === 'user/message' && event.data.source.rpcId === firstEntry.requestId)).toHaveLength(1);
    const duplicateWork = (await invoke('plugin.route.call', firstCommand)).payload.result;
    expect(duplicateWork).toEqual(firstWork); expect(adapter.calls).toBe(1);
    const changedCommand = { ...firstCommand, body: { ...firstCommand.body, payload: { ...firstCommand.body.payload, text: 'Changed task' } } };
    const conflictWork = (await invoke('plugin.route.call', changedCommand)).payload.result;
    expect(conflictWork.json.value).toMatchObject({ state: 'rejected', reason: 'payloadConflict', sessionId: null, revision: null });
    const secondCommand = command('fixture-work-second');
    const secondWork = (await invoke('plugin.route.call', secondCommand)).payload.result;
    expect(secondWork.json.value.state).toBe('accepted');
    const secondEntry = journal.lookup(workScope, secondCommand.body.payload)!;
    await until(() => adapter.waiting);
    const stop = (await invoke('harness.remote.call', { endpoint: 'session/cancel', payload: { args: { request: { sessionId: secondWork.json.value.sessionId } } } })).payload.result;
    expect(stop).toEqual({ ok: true, value: { accepted: true } });
    // The cancel ACK is not settlement; wait for official aborted turn evidence.
    await until(() => adapter.aborted && workEvents.some(event => event.type === 'turn/end' && event.data.reason?.kind === 'aborted')
      && journal.lookup(workScope, secondCommand.body.payload)?.pending === false);
    expect(workEvents.filter(event => event.type === 'user/message' && event.data.source.rpcId === secondEntry.requestId)).toHaveLength(1);
    const statusCommand = { route: 'api/bot', body: { endpoint: 'quenderin-command', payload: {
      schemaVersion: 1, workspaceId: workspace.id, botId: 'fixture-bot', commandId: firstCommand.body.payload.commandId,
    } } };
    expect((await invoke('plugin.route.call', statusCommand)).payload.result).toEqual(firstWork);
    const withoutScope = createPluginRouteDispatcher(() => ctx.connection, () => undefined, peer)!;
    expect((await withoutScope('api/bot', firstCommand.body, AbortSignal.timeout(1000))).status).toBe(503);
    expect(adapter.calls).toBe(2); expect(capabilityPreparations).toBe(2); expect(toolCalls).toBe(0);
    completed.work = { scriptedModelCalls: 2, capabilityPreparations, twoSequentialCommands: true, matchingMessages: [1, 1],
      duplicatePreserved: true, conflictPreserved: true, statusPreserved: true, stopAcknowledged: true, abortedTurnObserved: true,
      authenticatedInProcessScope: true, firstReceipt: firstWork, secondReceipt: secondWork };
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
    expect(mountedBotWork(connection)).toBeUndefined();
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
    if (previousJournal === undefined) delete process.env.QUENDERIN_BOT_WORK_JOURNAL; else process.env.QUENDERIN_BOT_WORK_JOURNAL = previousJournal;
    if (previousTrust === undefined) delete process.env.QUENDERIN_REMOTE_TRUST_FILE; else process.env.QUENDERIN_REMOTE_TRUST_FILE = previousTrust;
  }
});
