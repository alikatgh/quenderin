import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, chmodSync, symlinkSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { QuenderinApprovalPolicy, assertPeerAllowed, actionDigest } from '../quenderin-host-policy.mjs';

const payload = {args:{request:{address:{kind:'session',sessionId:'session'}}}};
const request = {toolName:'write',callId:'call-1',arguments:{path:'synthetic.txt',text:'fixture'}};
function fixture() {
  const clock = {epoch:1000000,mono:10};
  const policy = new QuenderinApprovalPolicy('host','client',()=>clock.epoch,()=>clock.mono);
  policy.observe('workspace/follow',{}, {type:'baseline',value:{items:[{workspaceId:'workspace',sessionIds:['session']}]}});
  policy.observe('session/follow',payload,{type:'snapshot',records:[{type:'event',event:{type:'turn/start',data:{turn:3}}}]});
  policy.observe('$events',{}, {type:'ready',clientId:'gateway-client'});
  const event = policy.observe('$events',{}, {type:'waterfall',event:'approval/request',eventId:'event',agentId:'session',request});
  const answer = {binding:{...event.quenderinBinding},clientId:'gateway-client',outcome:{kind:'result',value:'allowed-once'}};
  return {policy,clock,event,answer};
}

test('shared native canonicalization cases match the actual Host digest',()=>{
  const fixture=new URL('../../../shared/remote-harness-approval-digest-fixtures.json',import.meta.url);
  const document=JSON.parse(readFileSync(fixture,'utf8'));
  assert.equal(document.schemaVersion,1);
  for(const entry of document.cases) {
    const value=JSON.parse(entry.wireJSON);
    if(entry.hostExpectation==='reject') assert.throws(()=>actionDigest(value),entry.id);
    else {
      assert.equal(actionDigest(value),entry.sha256,entry.id);
      assert.equal(createHash('sha256').update(entry.canonicalJSON).digest('hex'),entry.sha256,entry.id);
    }
  }
});

test('local Host observation binds exact action, destination, device, run and expiry',()=>{
  const {policy,event,answer}=fixture();
  assert.deepEqual(event.quenderinBinding,{hostDeviceId:'host',clientDeviceId:'client',workspaceId:'workspace',sessionId:'session',
    runId:'turn:3',eventId:'event',actionDigest:actionDigest(request),expiresAt:1120000});
  assert.equal(request.quenderinBinding,undefined);
  assert.deepEqual(policy.consume(answer),{args:{clientId:'gateway-client',eventId:'event',outcome:{kind:'result',value:'allowed-once'}}});
  assert.throws(()=>policy.consume(answer));
});

for (const field of ['hostDeviceId','clientDeviceId','workspaceId','sessionId','runId','eventId','actionDigest','expiresAt']) {
  test(`changed binding ${field} cannot authorize`,()=>{
    const {policy,answer}=fixture(); answer.binding[field]=field==='expiresAt'?1120001:'changed';
    assert.throws(()=>policy.consume(answer));
  });
}

test('deny is equally bound and consumed once',()=>{
  const {policy,answer}=fixture(); answer.outcome.value='rejected';
  assert.equal(policy.consume(answer).args.outcome.value,'rejected');
  assert.throws(()=>policy.consume(answer));
});

test('reused event ID withdraws the old action even when the replacement is unbound',()=>{
  const {policy,answer}=fixture();
  const replacement=policy.observe('$events',{}, {type:'waterfall',event:'approval/request',eventId:'event',agentId:'session',request:{toolName:'delete',arguments:{path:'different.txt'}}});
  assert.equal(replacement.quenderinBinding,undefined);
  assert.throws(()=>policy.consume(answer));
});

test('a reused event ID with an unknown replacement scope still withdraws old authorization',()=>{
  const {policy,answer}=fixture();
  policy.observe('$events',{}, {type:'waterfall',event:'approval/request',eventId:'event',agentId:'unknown-session',request:{toolName:'delete'}});
  assert.throws(()=>policy.consume(answer));
});

for (const mutation of [
  f=>{f.clock.mono+=120000;},
  f=>{f.clock.mono=0;},
  f=>{f.policy.observe('$events',{}, {type:'cancel',eventId:'event'});},
  f=>{f.policy.observe('$events',{}, {type:'ready',clientId:'replacement'});},
  f=>{f.policy.observe('session/follow',payload,{type:'event',event:{type:'turn/end',data:{turn:3}}});},
  f=>{f.policy.observe('session/follow',payload,{type:'event',event:{type:'turn/start',data:{turn:4}}});},
  f=>{f.policy.observe('workspace/follow',{}, {type:'remove',workspaceId:'workspace'});},
  f=>{f.policy.streamClosed('$events');},
  f=>{f.policy.close();},
]) test('expired, withdrawn, replaced or retired decision cannot authorize',()=>{
  const f=fixture(); mutation(f); assert.throws(()=>f.policy.consume(f.answer));
});

test('wall clock rollback cannot extend the monotonic authorization lifetime',()=>{
  const f=fixture(); f.clock.epoch=1; f.clock.mono+=120000;
  assert.throws(()=>f.policy.consume(f.answer));
});

test('approval without authoritative workspace and turn remains presentation only',()=>{
  const policy=new QuenderinApprovalPolicy('host','client');
  policy.observe('$events',{}, {type:'ready',clientId:'gateway-client'});
  const event=policy.observe('$events',{}, {type:'waterfall',event:'approval/request',eventId:'event',agentId:'session',request});
  assert.equal(event.quenderinBinding,undefined);
});

test('workspace upsert is observed without inventing membership',()=>{
  const {policy,answer}=fixture();
  policy.observe('workspace/follow',{}, {type:'upsert',workspace:{workspaceId:'workspace',sessionIds:[]}});
  assert.throws(()=>policy.consume(answer));
});

test('JSON action digest is ordered, complete and bounded',()=>{
  assert.equal(actionDigest({b:[1,2],a:'x'}),actionDigest({a:'x',b:[1,2]}));
  assert.notEqual(actionDigest(request),actionDigest({...request,arguments:{path:'other'}}));
  assert.throws(()=>actionDigest({value:Infinity}));
  assert.throws(()=>actionDigest({value:'x'.repeat(65537)}));
  const cycle={};cycle.self=cycle;assert.throws(()=>actionDigest(cycle));
});

test('public trust pin must match exact identity and current file; revoke blocks access',()=>{
  // Caller supplies the already registered session scratch root when testing locally.
  const root=mkdtempSync(join(process.env.QUENDERIN_TEST_SCRATCH??tmpdir(),'host-policy-'));
  const file=join(root,'public-trust.json'), linked=join(root,'public-trust-link.json');
  const publicKey=Buffer.alloc(32,1).toString('base64url');
  try {
    writeFileSync(file,JSON.stringify({version:1,peers:[{deviceId:'client',publicKey}]}),{mode:0o600});
    assert.doesNotThrow(()=>assertPeerAllowed('client',publicKey,file));
    assert.throws(()=>assertPeerAllowed('other',publicKey,file));
    assert.throws(()=>assertPeerAllowed('client',Buffer.alloc(32,2).toString('base64url'),file));
    symlinkSync(file,linked);assert.throws(()=>assertPeerAllowed('client',publicKey,linked));
    chmodSync(file,0o666);assert.throws(()=>assertPeerAllowed('client',publicKey,file));
    chmodSync(file,0o600);writeFileSync(file,JSON.stringify({version:1,peers:[]}));
    assert.throws(()=>assertPeerAllowed('client',publicKey,file));
  } finally { rmSync(root,{recursive:true,force:true}); }
});

test('human pairing CLI creates only a confirmed new public policy',()=>{
  const root=mkdtempSync(join(process.env.QUENDERIN_TEST_SCRATCH??tmpdir(),'host-pairing-'));
  const file=join(root,'public-trust.json');
  const publicKey=Buffer.alloc(32,1).toString('base64url');
  const fingerprint='72cd6e8422c407fb6d098690f1130b7ded7ec2f7f5e1d30bd9d521f015363793';
  const script=new URL('../tools/trust_peer.mjs',import.meta.url).pathname;
  const run=(confirmation)=>spawnSync(process.execPath,[script,'--file',file,'--device','client','--public-key',publicKey,'--confirm-fingerprint',confirmation],{encoding:'utf8'});
  try {
    assert.equal(run('wrong').status,1);
    assert.equal(run(fingerprint).status,0);
    assert.doesNotThrow(()=>assertPeerAllowed('client',publicKey,file));
    const before=readFileSync(file,'utf8');
    assert.equal(run(fingerprint).status,1);
    assert.equal(readFileSync(file,'utf8'),before);
  } finally { rmSync(root,{recursive:true,force:true}); }
});
