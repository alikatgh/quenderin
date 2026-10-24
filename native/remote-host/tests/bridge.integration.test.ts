// Copied into the PINNED upstream plugin tests by remote-host.yml. Exercises the
// patched production bridge/controller; only the local Gateway and relay are fake.
import { describe, it, expect } from 'vitest'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { HarnessRemoteBridge } from '../src/harness-remote-bridge.js'
import { ConnectionController } from '../src/connection-controller.js'
import { QuenderinApprovalPolicy, APPROVAL_ENDPOINT } from '../src/quenderin-host-policy.mjs'
import { botSessionWritable, mountBotRead } from '../src/quenderin-bot-runtime.mjs'
import type { LocalTypertGateway } from '../src/typert-gateway-contract.js'
import type { RemoteMessage } from '@dsh-remote/protocol'

async function until(condition: () => boolean) {
  const deadline=Date.now()+1000
  while (!condition()) {
    if (Date.now()>deadline) throw new Error('Synthetic integration condition timed out')
    await new Promise(resolve=>setTimeout(resolve,1))
  }
}

const sessionPayload={args:{request:{address:{kind:'session',sessionId:'session'}}}}
const action={toolName:'write',callId:'call',arguments:{path:'synthetic.txt'}}
function gateway(calls: unknown[]): LocalTypertGateway {
  return {
    supportsCarrier:true,
    invoke:async()=>undefined,
    dispatch:async(endpoint,payload)=>{calls.push({endpoint,payload});return {ok:true,value:{received:true}}},
    open:async(endpoint,_payload,signal)=>(async function* () {
      if(endpoint==='workspace/follow') yield {type:'baseline',value:{items:[{workspaceId:'workspace',sessionIds:['session']}]}}
      if(endpoint==='session/follow') yield {type:'snapshot',records:[{type:'event',event:{type:'turn/start',data:{turn:1}}}]}
      if(endpoint==='$events') {
        yield {type:'ready',clientId:'gateway-client'}
        yield {type:'waterfall',event:'approval/request',agentId:'session',eventId:'event',request:action}
      }
      if(!signal.aborted) await new Promise<void>(resolve=>signal.addEventListener('abort',()=>resolve(),{once:true}))
    })(),
    failure:()=>({code:'FAILED',message:'',details:{}}),
  }
}

describe('Quenderin pinned production Host bridge',()=>{
  it('keeps Bot parts read-only while ordinary Harness prompts and Stop retain their existing path', async () => {
    const calls: unknown[] = [], disposers: (() => void)[] = [], connection = {};
    let ready = true;
    const runtime = { ctx: { connection, effect: (effect: () => () => void) => { disposers.push(effect()) } },
      state: { revision: 7, rooms: { room: { id: 'room' } }, bots: { bot: { id: 'bot', sessionId: 'bot-part' } } },
      chatOwners: new Map([['bot-part', 'bot']]), groupOwners: new Map(), pastOwners: new Map(),
      quenderinReadStatus: () => ({ ready, readOnly: false }) };
    mountBotRead(runtime);
    const bridge = new HarnessRemoteBridge(gateway(calls), async () => undefined, undefined, '0.2.1-rc.1', undefined, undefined, undefined,
      sessionId => botSessionWritable(connection, sessionId));
    const call = (endpoint: string, sessionId: string) => bridge.call({ endpoint, payload: { args: { request: { sessionId } } } });
    try {
      for (const endpoint of ['session/prompt', 'session/selectModel']) {
        await expect(call(endpoint, 'bot-part')).rejects.toThrow('read-only');
        await expect(call(endpoint, 'bot')).rejects.toThrow('read-only');
        await expect(call(endpoint, 'room')).rejects.toThrow('read-only');
        await call(endpoint, 'ordinary');
      }
      ready = false;
      await expect(call('session/prompt', 'ordinary')).rejects.toThrow('read-only');
      await call('session/cancel', 'bot-part');
      expect(calls).toHaveLength(3);
    } finally { await bridge.closeAll(); disposers.forEach(dispose => dispose()); }
  })
  it('emits a bound approval and forwards exactly one local official result',async()=>{
    const calls: unknown[]=[], frames: unknown[]=[]
    const policy=new QuenderinApprovalPolicy('host','client')
    const bridge=new HarnessRemoteBridge(gateway(calls),async(_event,data)=>{frames.push(data)},undefined,'0.2.1-rc.1',undefined,undefined,policy)
    try {
      await bridge.openStream({streamId:'workspaces',endpoint:'workspace/follow',payload:{args:{}}})
      await until(()=>frames.length>=1)
      await bridge.openStream({streamId:'history',endpoint:'session/follow',payload:sessionPayload})
      await until(()=>frames.length>=2)
      await bridge.openStream({streamId:'events',endpoint:'$events',payload:{args:{}}})
      await until(()=>frames.length>=4)
      const value=(frames[3] as {value:{quenderinBinding:unknown}}).value
      expect(value.quenderinBinding).toBeDefined()
      const payload={args:{binding:value.quenderinBinding,clientId:'gateway-client',outcome:{kind:'result',value:'allowed-once'}}}
      await bridge.call({endpoint:APPROVAL_ENDPOINT,payload})
      expect(calls).toEqual([{endpoint:'$events/result',payload:{args:{clientId:'gateway-client',eventId:'event',outcome:{kind:'result',value:'allowed-once'}}}}])
      await expect(bridge.call({endpoint:APPROVAL_ENDPOINT,payload})).rejects.toThrow()
      expect(calls).toHaveLength(1)
    } finally {await bridge.closeAll()}
  })

  it('blocks unbound, alternate mutation and terminal routes before Gateway dispatch',async()=>{
    const calls: unknown[]=[]
    const bridge=new HarnessRemoteBridge(gateway(calls),async()=>undefined)
    try {
      for(const endpoint of ['$events/result','commands/execute','terminal/write','pluginManager/setPluginEnabled','workspace/create']) {
        await expect(bridge.call({endpoint,payload:{args:{}}})).rejects.toThrow()
      }
      for(const endpoint of ['terminal/follow','pluginManager/follow']) {
        await expect(bridge.openStream({streamId:'blocked',endpoint,payload:{args:{}}})).rejects.toThrow()
      }
      expect(calls).toHaveLength(0)
    } finally {await bridge.closeAll()}
  })

  it('rechecks revocation after an awaited RPC before sending its result',async()=>{
    const root=mkdtempSync(join(tmpdir(),'quenderin-host-integration-')), file=join(root,'public-trust.json')
    const publicKey=Buffer.alloc(32,1).toString('base64url')
    const oldPath=process.env.QUENDERIN_REMOTE_TRUST_FILE
    process.env.QUENDERIN_REMOTE_TRUST_FILE=file
    writeFileSync(file,JSON.stringify({version:1,peers:[{deviceId:'client',publicKey}]}),{mode:0o600})
    let resolve!: (value:RemoteMessage)=>void, started=false, closed=false, receive:((value:RemoteMessage)=>void)|undefined
    const sent:RemoteMessage[]=[]
    const response=new Promise<RemoteMessage>(done=>{resolve=done})
    const controller=new ConnectionController({isTrusted:()=>true} as never,()=>({handle:()=>{started=true;return response},closePeerStreams:async()=>undefined}) as never)
    try {
      await controller.accept({security:{protocol:'Noise_IK_25519_ChaChaPoly_SHA256',connectionId:'connection',membershipId:'membership'},peerDeviceId:'client',peerIdentityKey:publicKey,
        send:async value=>{sent.push(value)},onMessage:handler=>{receive=handler;return()=>{receive=undefined}},close:async()=>{closed=true}})
      receive?.({v:1,id:'request',type:'rpc.request',timestamp:1,payload:{method:'harness.remote.call',params:{endpoint:'session/list',payload:{args:{_request:{}}}}}})
      await until(()=>started)
      writeFileSync(file,JSON.stringify({version:1,peers:[]}))
      resolve({v:1,id:'response',type:'rpc.response',timestamp:2,payload:{requestId:'request',result:{ok:true,value:'private synthetic content'}}})
      await until(()=>closed)
      expect(sent).toHaveLength(0)
    } finally {
      await controller.close()
      if(oldPath===undefined) delete process.env.QUENDERIN_REMOTE_TRUST_FILE
      else process.env.QUENDERIN_REMOTE_TRUST_FILE=oldPath
      rmSync(root,{recursive:true,force:true})
    }
  })
})
