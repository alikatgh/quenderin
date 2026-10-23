// Service assembly and scripted chunk vocabulary follow the pinned MIT
// DeepSeek test-support patterns; see LICENSE.DeepSeek and README attribution.
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
import { AttachmentStore, type ImageAttachmentLimits } from '@deepseek-ai/dsh-attachment';
import Commands from '@deepseek-ai/dsh-commands';
import { HostConnectionService } from '@deepseek-ai/dsh-client-connection';
import FileUploads from '@deepseek-ai/dsh-client-file-upload';
import { LlmAdapter, ToolCallId, type GenerateOptions, type StreamChunk } from '@deepseek-ai/dsh-llm';
import { defineTool } from '@deepseek-ai/dsh-tools';
import * as Persistence from '@deepseek-ai/dsh-session-persistence-jsonl';
import { SessionQueryEngine } from '@deepseek-ai/dsh-session-query';
import Storage from '@deepseek-ai/dsh-storage';
import * as JsonStorage from '@deepseek-ai/dsh-storage-json';
import * as StorageDomain from '@deepseek-ai/dsh-storage-domain';
import WorkspaceRegistry from '@deepseek-ai/dsh-workspace';
import Approval from '@deepseek-ai/dsh-user-approval';
import { SessionId } from '@deepseek-ai/dsh-session';
import { HarnessRemoteBridge } from '@quenderin/patched-host-bridge';
import { TypertGatewaySwitch } from '@quenderin/upstream-gateway-switch';
import { QuenderinApprovalPolicy, APPROVAL_ENDPOINT } from '@quenderin/host-policy';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

// These boundaries are outside the text/point-read journey. The inherited
// production admission, exact-read, list, follow and projection methods run.
// No fixture search index or media implementation pretends to be a backend.
class TextOnlyAttachments extends AttachmentStore {
  // Production projection metadata requires five positive integer bounds.
  // No media type is admitted, and every media operation below still rejects.
  readonly imageLimits: ImageAttachmentLimits = { maxImageBytes: 1, maxImagesPerMessage: 1, maxMessageImageBytes: 1, maxImagePixels: 1, maxImageDimension: 1, mediaTypes: [] };
  async validateImage(): Promise<never> { throw new Error('Media outside this fixture'); }
  async saveImage(): Promise<never> { throw new Error('Media outside this fixture'); }
  async readImage(): Promise<never> { throw new Error('Media outside this fixture'); }
}
class PointReadQuery extends SessionQueryEngine {
  async searchSessions(): Promise<never> { throw new Error('Search outside this fixture'); }
  async searchEvents(): Promise<never> { throw new Error('Search outside this fixture'); }
}

// This is an adapter only: every turn, Inbox admission, request, tool dispatch,
// approval and Session event is produced by the installed official runtime.
class CredentialFreeAdapter extends LlmAdapter {
  readonly requests: GenerateOptions[] = [];
  async resolveModel(provider: string, model: string) { return { provider, id: model, name: model }; }
  async *stream(options: GenerateOptions): AsyncIterable<StreamChunk> {
    options.signal?.throwIfAborted();
    this.requests.push(options);
    if (this.requests.length > 2) throw new Error('Two-call synthetic model budget exceeded');
    if (this.requests.length === 1) {
      const id = ToolCallId('fixture-call-1');
      const args = '{"text":"synthetic action"}';
      yield { type: 'block-start', index: 0, blockType: 'tool-call' };
      yield { type: 'tool-call-delta', index: 0, id, name: 'fixture_echo', argumentsDelta: args };
      yield { type: 'block-end', index: 0, block: { type: 'tool-call', id, name: 'fixture_echo', arguments: args } };
      yield { type: 'finish', reason: { kind: 'tool-calls' } };
    } else {
      const text = 'Synthetic tool completed.';
      yield { type: 'block-start', index: 0, blockType: 'text' };
      yield { type: 'text-delta', index: 0, text };
      yield { type: 'block-end', index: 0, block: { type: 'text', text } };
      yield { type: 'finish', reason: { kind: 'stop' } };
    }
  }
}

type Fact = Record<string, any>;
async function until(predicate: () => boolean, label: string) {
  const deadline = performance.now() + 1500;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error(`Runtime condition timed out: ${label}`);
    await new Promise(done => setTimeout(done, 1));
  }
}
function success<T = any>(result: any): T {
  expect(result).toMatchObject({ ok: true });
  return result.value;
}

it('runs a native prompt through strict production SessionV3 Gateway, Agent, approval and tool dispatch', async () => {
  const root = process.env.QUENDERIN_FIXTURE_ROOT;
  if (!root?.startsWith('/')) throw new Error('Runner-owned temporary root required');
  const ctx = new Context();
  const frames: Fact[] = [], unary: Fact[] = [];
  let bridge: HarnessRemoteBridge | undefined;
  let executions = 0;
  let completedFacts: string | undefined;
  const adapter = new CredentialFreeAdapter();
  const lifetime = new AbortController();
  try {
    await ctx.plugin(TypertRegistry);
    await ctx.plugin(RemoteAccess);
    await mountAgentLoopTestDependencies(ctx, { workingDirectory: true });
    await ctx.plugin(Storage);
    await ctx.plugin(JsonStorage, { root: join(root, 'domain-json') });
    await ctx.plugin(StorageDomain, { backend: 'json' });
    await ctx.plugin(Persistence, { root: join(root, 'sessions'), compression: 'none', listConcurrency: 1 });
    await ctx.plugin(WorkspaceRegistry);
    await mountAgentLoopTestHarness(ctx);
    await ctx.plugin(DefaultModel, { provider: 'fixture', model: 'scripted' });
    ctx.llm.registerAdapter(['fixture'], adapter);
    new TextOnlyAttachments(ctx);
    new PointReadQuery(ctx);
    await ctx.plugin(Commands);
    // HTTP is never mounted. Browser-auth methods throw if accidentally used;
    // only the official in-process Peer + registration facilities are needed.
    const noBrowserAuth = new Proxy({}, { get() { throw new Error('Browser authentication outside this fixture'); } });
    new HostConnectionService(ctx, [], noBrowserAuth as never);
    await ctx.plugin(FileUploads);
    await ctx.plugin(Approval, { policy: 'ask' });
    ctx.tools.register(defineTool({
      name: 'fixture_echo', description: 'Return a fixed synthetic result without I/O',
      parameters: { text: { type: 'string' } },
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      async execute(args) {
        if (++executions !== 1 || args.text !== 'synthetic action') throw new Error('One inert tool-call budget exceeded');
        return 'synthetic result';
      },
    }));
    ctx.on('tools/pre-execute', async (execution) => execution.name === 'fixture_echo'
      ? { kind: 'ask', reason: 'Synthetic fixture approval' } : { kind: 'deny', reason: 'Tool outside fixture' });
    ctx.effect(() => ctx.typert.register(SESSION));
    ctx.effect(() => ctx.typert.register(WORKSPACE));
    await ctx.plugin(SessionController, { nativeOpen: false });
    await ctx.plugin(WorkspaceController, { documentsDirectory: root });
    await ctx.plugin(Gateway, { streamInboxBytes: 65_536 });
    await ctx.plugin(ApiRemotes);

    // Assert the generated definitions actually own these routes. SRC fallback
    // alone cannot satisfy this fixture even if the output happened to match.
    for (const [namespace, method] of [['session', 'create'], ['session', 'list'], ['session', 'prompt'], ['session', 'follow'], ['session', 'control'], ['workspace', 'follow']]) {
      expect(ctx.typert.local.get(`${namespace}/${method}`)).toBeDefined();
    }
    const peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' });
    const local = new TypertGatewaySwitch(ctx.typertGateway).local(peer);
    expect(local.supportsCarrier).toBe(true);
    const policy = new QuenderinApprovalPolicy('fixture-host', 'fixture-native');
    bridge = new HarnessRemoteBridge(local, async (event, data) => {
      if (frames.length >= 128 || Buffer.byteLength(JSON.stringify(data)) > 49_152) throw new Error('Bounded runtime-frame budget exceeded');
      frames.push({ event, ...data });
    }, undefined, '0.2.1-rc.1', undefined, undefined, policy);
    const call = async (endpoint: string, args: object) => {
      const result = await bridge!.call({ endpoint, payload: { args } });
      unary.push({ endpoint, result });
      return success(result);
    };
    const open = async (streamId: string, endpoint: string, args: object) => bridge!.openStream({ streamId, endpoint, payload: { args } });
    const values = (streamId: string) => frames.filter(frame => frame.streamId === streamId && frame.value !== undefined).map(frame => frame.value);
    await open('workspace-feed', 'workspace/follow', {});
    await until(() => values('workspace-feed').some(value => value.type === 'baseline'), 'Workspace baseline');
    // Host registration is setup. Workspace mutation remains unavailable through
    // the native bridge; session/create subsequently uses the actual Workspace.
    const cwd = join(root, 'workspace');
    mkdirSync(cwd);
    const workspace: any = await ctx.typertGateway.invoke({ peer, namespace: 'workspace', method: 'create', args: { request: { path: cwd } }, signal: lifetime.signal });
    unary.push({ endpoint: 'workspace/create (Host setup)', result: { ok: true, value: workspace } });
    const workspaceId = workspace.workspace.workspaceId;
    const created = await call('session/create', { request: { workspaceId, sessionId: SessionId('fixture-session') } });
    const sessionId = created.sessionId;
    const listed = await call('session/list', { _request: {} });
    expect(listed.items.some((item: any) => item.sessionId === sessionId)).toBe(true);
    await until(() => values('workspace-feed').some(value => value.type === 'upsert' && value.workspace.sessionIds.includes(sessionId)), 'Session Workspace membership');
    await open('session-history', 'session/follow', { request: { address: { kind: 'session', sessionId }, maxMessages: 60, assistantStream: true } });
    await open('session-control', 'session/control', {});
    await open('remote-events', '$events', {});
    await until(() => values('session-history').some(value => value.type === 'snapshot')
      && values('session-control').some(value => value.type === 'baseline')
      && values('remote-events').some(value => value.type === 'ready'), 'All three live baselines');
    const requestId = 'fixture-native-prompt-1';
    const receipt = await call('session/prompt', { request: {
      sessionId, requestId, mode: 'queue', content: [{ type: 'text', text: 'Run the synthetic fixture tool once.' }],
    } });
    expect(receipt).toEqual({ accepted: true });
    await until(() => values('remote-events').some(value => value.type === 'waterfall' && value.event === 'approval/request'), 'Genuine approval');
    const approval = values('remote-events').find(value => value.type === 'waterfall' && value.event === 'approval/request');
    expect(approval.agentId).toBe(sessionId);
    expect(approval.request.toolName).toBe('fixture_echo');
    expect(approval.quenderinBinding).toMatchObject({ workspaceId, sessionId, hostDeviceId: 'fixture-host', clientDeviceId: 'fixture-native' });
    expect(executions).toBe(0);
    const clientId = values('remote-events').find(value => value.type === 'ready').clientId;
    const answer = { binding: approval.quenderinBinding, clientId, outcome: { kind: 'result', value: 'allowed-once' } };
    await call(APPROVAL_ENDPOINT, answer);
    await expect(bridge.call({ endpoint: APPROVAL_ENDPOINT, payload: { args: answer } })).rejects.toThrow();
    await until(() => values('session-history').some(value => value.type === 'event' && value.event.type === 'turn/end'), 'Genuine turn completion');
    expect(executions).toBe(1);
    expect(adapter.requests).toHaveLength(2);
    const agent = ctx.agents.get(SessionId(sessionId))!;
    const events = agent.session.snapshotEvents();
    const end = events.findLast(event => event.type === 'turn/end');
    expect(end?.data.reason).toMatchObject({ kind: 'completed' });
    expect(events.filter(event => event.type === 'user/message' && event.data.source.rpcId === requestId)).toHaveLength(1);
    expect(events.some(event => event.type === 'approval/asked')).toBe(true);
    expect(events.some(event => event.type === 'approval/decided')).toBe(true);

    // Capture observed production DTOs only after the full journey succeeds.
    const names = new Map([[workspaceId, 'fixture-workspace'], [sessionId, 'fixture-session'], [clientId, 'fixture-event-client'],
      [approval.eventId, 'fixture-event'], [homedir(), '<host-home>'], [root, '<fixture-root>']]);
    const canonical = (value: any, key = ''): any => {
      if (typeof value === 'string') {
        if (names.has(value)) return names.get(value);
        if (value.startsWith(root)) return value.replace(root, '<fixture-root>');
        return value;
      }
      if (typeof value === 'number' && ['time', 'createdAt', 'updatedAt', 'expiresAt', 'timestamp'].includes(key)) return 2_000_000_000_000;
      if (Array.isArray(value)) return value.map(item => canonical(item));
      if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [names.get(key) ?? key, canonical(item, key)]));
      return value;
    };
    const facts = canonical({ schema: 1, runtime: 'official-0.2.1-rc.1', source: '1600d8a1e140dcde43a1a0941940a0480712c011',
      bridge: 'patched-production', scriptedModelCalls: adapter.requests.length, inertToolExecutions: executions, unary, frames });
    const encoded = JSON.stringify(facts, null, 2) + '\n';
    if (Buffer.byteLength(encoded) > 262_144) throw new Error('Canonical facts exceed 256 KiB');
    completedFacts = encoded;
  } catch (error) {
    // This keyless synthetic fixture may report internal failure text, but no
    // raw DTO, profile, prompt, environment or successful runtime facts.
    const token = (value: unknown) => typeof value === 'string' && /^[A-Za-z0-9_./-]{1,80}$/.test(value) ? value : undefined;
    const message = (value: unknown) => typeof value === 'string'
      ? value.replaceAll(root, '<fixture-root>').replaceAll(homedir(), '<host-home>')
        .replace(/https?:\/\/[^\s"']+/g, '<url>').slice(0, 160)
      : undefined;
    const streams = ['workspace-feed', 'session-history', 'session-control', 'remote-events'].map(streamId => {
      const observed = frames.filter(frame => frame.streamId === streamId);
      const terminal = observed.findLast(frame => frame.event === 'harness.remote.stream.closed');
      return { streamId, frames: observed.length,
        valueTypes: [...new Set(observed.map(frame => token(frame.value?.type)).filter(Boolean))].slice(0, 6),
        terminal: terminal === undefined ? undefined : { event: 'harness.remote.stream.closed', reason: token(terminal.reason),
          code: token(terminal.failure?.code), message: message(terminal.failure?.message) } };
    });
    const diagnostic = { officialRuntimeFailure: 'stream-baselines-or-journey', streams };
    let encoded = JSON.stringify(diagnostic);
    while (Buffer.byteLength(encoded) > 2048 && diagnostic.streams.length) {
      diagnostic.streams.pop();
      encoded = JSON.stringify(diagnostic);
    }
    console.error('OFFICIAL_RUNTIME_FAILURE_DIAGNOSTIC ' + encoded);
    throw error;
  } finally {
    lifetime.abort();
    await bridge?.closeAll();
    await ctx.fiber.dispose();
  }
  const output = process.env.QUENDERIN_FIXTURE_FACTS;
  if (!completedFacts || !output?.startsWith('/')) throw new Error('Successful journey and absolute hosted artifact output path required');
  writeFileSync(resolve(output), completedFacts, { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ officialRuntimeJourney: 'passed', modelCalls: 2, toolExecutions: 1, frames: frames.length }));
});

class AbortableStalledAdapter extends LlmAdapter {
  readonly requests: GenerateOptions[] = [];
  waiting = false;
  aborted = false;
  constructor(private readonly maxCalls: number) { super(); }
  async resolveModel(provider: string, model: string) { return { provider, id: model, name: model }; }
  async *stream(options: GenerateOptions): AsyncIterable<StreamChunk> {
    this.requests.push(options);
    if (this.requests.length > this.maxCalls) throw new Error('Recovery model-call budget exceeded');
    const signal = options.signal;
    if (!signal) throw new Error('Stalled model requires the production cancellation signal');
    signal.throwIfAborted();
    yield { type: 'block-start', index: 0, blockType: 'text' };
    yield { type: 'text-delta', index: 0, text: 'Synthetic partial reply.' };
    let abort!: () => void;
    try {
      this.waiting = true;
      await new Promise<void>(done => {
        abort = () => { this.aborted = true; done(); };
        if (signal.aborted) abort();
        else signal.addEventListener('abort', abort, { once: true });
      });
      signal.throwIfAborted();
    } finally {
      this.waiting = false;
      signal.removeEventListener('abort', abort);
    }
  }
}

// A second fixture assembly owns its own storage and contexts. The first
// passing journey and its sole facts writer above remain unchanged.
async function mountRecoveryHost(root: string, adapter: AbortableStalledAdapter, budget: { toolCalls: number }) {
  const ctx = new Context();
  try {
    await ctx.plugin(TypertRegistry);
    await ctx.plugin(RemoteAccess);
    await mountAgentLoopTestDependencies(ctx, { workingDirectory: true });
    await ctx.plugin(Storage);
    await ctx.plugin(JsonStorage, { root: join(root, 'domain-json') });
    await ctx.plugin(StorageDomain, { backend: 'json' });
    await ctx.plugin(Persistence, { root: join(root, 'sessions'), compression: 'none', listConcurrency: 1 });
    await ctx.plugin(WorkspaceRegistry);
    await mountAgentLoopTestHarness(ctx);
    await ctx.plugin(DefaultModel, { provider: 'fixture', model: 'scripted' });
    ctx.llm.registerAdapter(['fixture'], adapter);
    new TextOnlyAttachments(ctx);
    new PointReadQuery(ctx);
    await ctx.plugin(Commands);
    const noBrowserAuth = new Proxy({}, { get() { throw new Error('Browser authentication outside this fixture'); } });
    new HostConnectionService(ctx, [], noBrowserAuth as never);
    await ctx.plugin(FileUploads);
    await ctx.plugin(Approval, { policy: 'ask' });
    ctx.on('tools/pre-execute', async () => {
      budget.toolCalls += 1;
      throw new Error('Zero-tool recovery budget exceeded');
    });
    ctx.effect(() => ctx.typert.register(SESSION));
    ctx.effect(() => ctx.typert.register(WORKSPACE));
    await ctx.plugin(SessionController, { nativeOpen: false });
    await ctx.plugin(WorkspaceController, { documentsDirectory: root });
    await ctx.plugin(Gateway, { streamInboxBytes: 65_536 });
    await ctx.plugin(ApiRemotes);
    return ctx;
  } catch (error) {
    await ctx.fiber.dispose();
    throw error;
  }
}

it('confirms real stop, reconciles reopened streams, and deduplicates one flushed prompt after a cold Context restart', async () => {
  const parent = process.env.QUENDERIN_FIXTURE_ROOT;
  if (!parent?.startsWith('/')) throw new Error('Runner-owned temporary root required');
  const root = join(parent, 'stop-cold-recovery');
  mkdirSync(root);
  const budget = { toolCalls: 0 };
  const warmAdapter = new AbortableStalledAdapter(1);
  const coldAdapter = new AbortableStalledAdapter(0);
  let warm: Context | undefined, cold: Context | undefined;
  let bridge: HarnessRemoteBridge | undefined;
  let peer: ReturnType<Context['connection']['createPeer']> | undefined;
  let phase = 'mount-warm';
  let capturedFrames = 0;
  const frames: Fact[] = [];
  const values = (streamId: string) => frames.filter(frame => frame.streamId === streamId && frame.value !== undefined).map(frame => frame.value);
  const connect = (ctx: Context) => {
    peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' });
    const local = new TypertGatewaySwitch(ctx.typertGateway).local(peer);
    expect(local.supportsCarrier).toBe(true);
    bridge = new HarnessRemoteBridge(local, async (event, data) => {
      if (++capturedFrames > 128 || Buffer.byteLength(JSON.stringify(data)) > 49_152) throw new Error('Recovery frame budget exceeded');
      frames.push({ event, ...data });
    }, undefined, '0.2.1-rc.1', undefined, undefined, new QuenderinApprovalPolicy('recovery-host', 'recovery-native'));
  };
  const disconnect = async () => {
    await bridge?.closeAll();
    await peer?.dispose();
    bridge = undefined;
    peer = undefined;
  };
  const call = async (endpoint: string, request: object) => success(await bridge!.call({ endpoint, payload: { args: { request } } }));
  const openBusinessStreams = async (sessionId: string, generation: string) => {
    await bridge!.openStream({ streamId: `${generation}-workspace`, endpoint: 'workspace/follow', payload: { args: {} } });
    await bridge!.openStream({ streamId: `${generation}-history`, endpoint: 'session/follow',
      payload: { args: { request: { address: { kind: 'session', sessionId }, maxMessages: 60, assistantStream: true } } } });
    await bridge!.openStream({ streamId: `${generation}-control`, endpoint: 'session/control', payload: { args: {} } });
    await bridge!.openStream({ streamId: `${generation}-events`, endpoint: '$events', payload: { args: {} } });
    await until(() => values(`${generation}-workspace`).some(value => value.type === 'baseline')
      && values(`${generation}-history`).some(value => value.type === 'snapshot')
      && values(`${generation}-control`).some(value => value.type === 'baseline')
      && values(`${generation}-events`).some(value => value.type === 'ready'), `${generation} recovery baselines`);
  };
  const matchingMessages = (records: Fact[], requestId: string) => records.filter(record => record.type === 'event'
    && record.event.type === 'user/message' && record.event.data.source.rpcId === requestId);
  try {
    warm = await mountRecoveryHost(root, warmAdapter, budget);
    connect(warm);
    const cwd = join(root, 'workspace');
    mkdirSync(cwd);
    const workspace: any = await warm.typertGateway.invoke({ peer: peer!, namespace: 'workspace', method: 'create', args: { request: { path: cwd } } });
    const sessionId = (await call('session/create', { workspaceId: workspace.workspace.workspaceId, sessionId: SessionId('fixture-recovery-session') })).sessionId;
    await openBusinessStreams(sessionId, 'running');
    const request = { sessionId, requestId: 'fixture-persisted-prompt-1', mode: 'queue', content: [{ type: 'text', text: 'Stream a partial synthetic reply, then wait for Stop.' }] };
    phase = 'stalled-model';
    expect(await call('session/prompt', request)).toEqual({ accepted: true });
    await until(() => warmAdapter.waiting && values('running-history').some(value => value.type === 'assistant-stream'), 'Real stalled model stream');
    const agent = warm.agents.get(SessionId(sessionId))!;
    expect(agent.status).toBe('running');
    phase = 'cancel-and-confirm';
    // This receipt admits cancellation. Only the subsequent official aborted
    // turn/end and idle Agent confirm that execution actually stopped.
    expect(await call('session/cancel', { sessionId })).toEqual({ accepted: true });
    await until(() => values('running-history').some(value => value.type === 'event' && value.event.type === 'turn/end'
      && value.event.data.reason.kind === 'aborted'), 'Authoritative aborted turn/end');
    await agent.whenIdle();
    expect(agent.status).toBe('idle');
    expect(warmAdapter.aborted).toBe(true);
    expect(warmAdapter.requests).toHaveLength(1);
    expect(budget.toolCalls).toBe(0);
    phase = 'reopen-business-streams';
    await disconnect();
    connect(warm);
    await openBusinessStreams(sessionId, 'reconciled');
    const snapshot = values('reconciled-history').find(value => value.type === 'snapshot');
    expect(snapshot.hasMore).toBe(false);
    expect(snapshot.assistantStream.activeAttempt).toBeUndefined();
    expect(matchingMessages(snapshot.records, request.requestId)).toHaveLength(1);
    const stopped = snapshot.records.find((record: Fact) => record.type === 'event' && record.event.type === 'turn/end').event;
    expect(stopped.data.reason).toMatchObject({ kind: 'aborted', reason: { kind: 'user' } });
    // Wire cursors name the last committed event; Session.seq is the next seq.
    expect(snapshot.cursor).toBe(agent.session.seq - 1);
    phase = 'flush-and-dispose-warm';
    const warmPersistence = warm.sessionPersistence.identity;
    await warm.sessionPersistence.flush();
    await disconnect();
    await warm.fiber.dispose();
    warm = undefined;
    phase = 'mount-cold';
    cold = await mountRecoveryHost(root, coldAdapter, budget);
    expect(cold.sessionPersistence.identity).not.toBe(warmPersistence);
    expect(cold.agents.get(SessionId(sessionId))).toBeUndefined();
    connect(cold);
    phase = 'cold-authoritative-page';
    const coldPage = await call('session/page', { address: { kind: 'session', sessionId }, throughSeq: snapshot.cursor, maxMessages: 60 });
    expect(coldPage.hasMore).toBe(false);
    expect(cold.agents.get(SessionId(sessionId))).toBeUndefined();
    expect(matchingMessages(coldPage.records, request.requestId)).toHaveLength(1);
    const coldEnd = coldPage.records.find((record: Fact) => record.type === 'event' && record.event.type === 'turn/end').event;
    expect(coldEnd).toEqual(stopped);
    expect(coldAdapter.requests).toHaveLength(0);
    phase = 'sequential-persisted-duplicate';
    expect(await call('session/prompt', request)).toEqual({ accepted: true });
    const resumed = cold.agents.get(SessionId(sessionId))!;
    await resumed.whenIdle();
    expect(resumed.status).toBe('idle');
    expect(coldAdapter.requests).toHaveLength(0);
    const restored = resumed.session.snapshotEvents();
    expect(restored.filter(event => event.type === 'user/message' && event.data.source.rpcId === request.requestId)).toHaveLength(1);
    expect(restored.filter(event => event.type === 'turn/start')).toHaveLength(1);
    expect(restored.filter(event => event.type === 'turn/end')).toHaveLength(1);
    expect(budget.toolCalls).toBe(0);
    await cold.sessionPersistence.flush();
  } catch (error) {
    const observed = frames.slice(-8).map(frame => ({ streamId: frame.streamId, type: frame.value?.type, reason: frame.reason,
      code: frame.failure?.code, message: typeof frame.failure?.message === 'string'
        ? frame.failure.message.replaceAll(root, '<fixture-root>').replaceAll(homedir(), '<host-home>').replace(/https?:\/\/[^\s"']+/g, '<url>').slice(0, 120) : undefined }));
    const diagnostic = { officialRecoveryFailure: phase, warmModelCalls: warmAdapter.requests.length, coldModelCalls: coldAdapter.requests.length, observed };
    let encoded = JSON.stringify(diagnostic);
    while (Buffer.byteLength(encoded) > 2048 && observed.length) { observed.pop(); encoded = JSON.stringify(diagnostic); }
    console.error('OFFICIAL_RUNTIME_RECOVERY_DIAGNOSTIC ' + encoded);
    throw error;
  } finally {
    await disconnect();
    await cold?.fiber.dispose();
    await warm?.fiber.dispose();
  }
  console.log(JSON.stringify({ officialRuntimeRecovery: 'passed', warmModelCalls: 1, coldModelCalls: 0,
    toolExecutions: 0, sequentialPromptAdmissions: 2, persistedUserMessages: 1, stop: 'aborted' }));
});
