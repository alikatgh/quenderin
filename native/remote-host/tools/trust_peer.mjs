#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import { constants, openSync, closeSync, writeFileSync, fsyncSync } from 'node:fs';
import { resolve } from 'node:path';

// Public pairing data only. Run by the human on the Host after comparing the
// complete fingerprint displayed on the mobile device. Never opens identity or credential files.
try {
  const {values} = parseArgs({options:{file:{type:'string'},device:{type:'string'},'public-key':{type:'string'},'confirm-fingerprint':{type:'string'}}});
  const file=values.file, device=values.device, key=values['public-key'], confirmation=values['confirm-fingerprint'];
  if (!file || resolve(file)!==file || !device || Buffer.byteLength(device)>1024 || device.includes('\0')
      || !key || !/^[A-Za-z0-9_-]{43}$/.test(key) || Buffer.from(key,'base64url').toString('base64url')!==key) throw Error();
  const fingerprint=createHash('sha256').update(Buffer.from(key,'base64url')).digest('hex');
  if (confirmation!==fingerprint) throw Error();
  // Create only: existing trust policy and every existing pin remain untouched.
  const descriptor=openSync(file,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
  try {
    const config={version:1,peers:[{deviceId:device,publicKey:key}]};
    const encoded=Buffer.from(JSON.stringify(config,null,2)+'\n');
    if (encoded.length>65536) throw Error();
    writeFileSync(descriptor,encoded,{flush:true});
    fsyncSync(descriptor);
  } finally { closeSync(descriptor); }
  console.log('Public client identity confirmed. Start/reconnect the Host with QUENDERIN_REMOTE_TRUST_FILE pointing at this file.');
} catch {
  console.error('Pairing not saved. Supply a NEW absolute public-trust file, device ID, canonical public identity and its exact SHA-256 fingerprint. Existing policy files are never replaced.');
  process.exitCode=1;
}
