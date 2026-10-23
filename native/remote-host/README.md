# Quenderin Host companion

This companion closes the trust and approval gaps between the native Quenderin
clients and `ds-harness-remote` **0.5.17**, source
`9a60e783ec1ceaff6116b0462a2863f07f602a55`. Harness continues to own the model,
tools and session. No provider key is transferred to Quenderin.

This is source preparation, not an installed or live-tested Host. Store submission
is deferred. Use an existing user-operated HTTPS relay; no Quenderin service or
paid infrastructure is provisioned by this repository.

The initial companion targets **macOS and Linux Hosts**. Public-policy ownership
and symlink checks use POSIX filesystem semantics. A native Windows trust-policy
adapter is still required; a Windows path must not be represented as validated by
these checks. Android/iOS/macOS are the native client targets, independently of
the Host operating system.

## Prepare the computer

1. Use a separate source checkout at the exact upstream revision. Keep an existing
   working Harness installation and its profile in place.
2. From this repository, check the four Host source hashes and patch seams:

   ```sh
   python3 native/remote-host/tools/prepare_host.py /absolute/path/to/ds-harness-remote
   ```

3. Apply the reviewed source change when the check succeeds:

   ```sh
   python3 native/remote-host/tools/prepare_host.py /absolute/path/to/ds-harness-remote --apply
   ```

   The tool adds two companion source files and edits four verified source files.
   It refuses another revision, changed seams, linked source files, or an existing
   companion. It does not download, install, start, authenticate or configure
   Harness. The upstream MIT notice is retained in `LICENSE.upstream`.

4. In that upstream checkout, build using the pinned workspace recipe:

   ```sh
   corepack pnpm@9.15.4 install --frozen-lockfile --ignore-scripts
   corepack pnpm@9.15.4 --filter './packages/**' -r build
   ```

   The hosted integration workflow checks the actual patched bundle. The
   unmodified npm package does **not** contain this companion. Do not substitute
   the old version in upstream's dated package README for the pinned source.

5. On the computer, use the official Harness launcher to install the prepared
   local bundle into the intended existing profile, for example:

   ```sh
   dsh plugin --profile web add file:/absolute/path/to/ds-harness-remote/packages/plugin
   ```

   Select the actual profile in use (`desktop` uses Desktop's official launcher).
   This is a manual installation step, not something the preparation script or
   CI performs. The official
   [local-bundle installation contract](https://github.com/deepseek-ai/deepseek-harness/blob/master/python/sdk/README.md)
   documents the `file:` form. A successful build does not establish that the
   user's installed Harness version/profile has loaded the companion.

## Confirm both identities

Quenderin displays its **public** device ID, public identity and complete SHA-256
fingerprint after enrollment. On the computer, compare that fingerprint and
create a new public trust file using these public values:

```sh
node native/remote-host/tools/trust_peer.mjs \
  --file /absolute/private-directory/quenderin-public-trust.json \
  --device PUBLIC_DEVICE_ID \
  --public-key PUBLIC_BASE64URL_IDENTITY \
  --confirm-fingerprint COMPLETE_LOWERCASE_SHA256
```

The command only creates a new file. It never opens or replaces existing trust,
identity, token or provider files. Additional devices and revocation are explicit
edits to this small public policy, whose format is:

```json
{"version":1,"peers":[{"deviceId":"PUBLIC_DEVICE_ID","publicKey":"PUBLIC_BASE64URL_IDENTITY"}]}
```

Start the prepared Host through its existing launch route with the nonsecret
`QUENDERIN_REMOTE_TRUST_FILE` setting pointing at that absolute file. Run under
the file's owner, with permissions `0600` (no group/world write). Keep credentials
in the existing Host credential system; this variable contains only a path.

The patched Host's identity-ready log adds `pairingFingerprintSHA256`, derived
only from its public identity. Compare the complete value in Quenderin before
trusting that computer. A changed pin requires explicit re-enrollment. Neither
the relay account nor an abbreviated display fingerprint establishes this trust.

The Host rejects unknown clients before upstream's automatic pinning. The
authenticated channel also checks the public policy on every receive/send and
every two seconds, closing revoked access. A missing, unreadable, linked,
oversized or insecure policy fails closed. Removing a device from the policy
prevents reconnect. Revocation does not itself cancel a task already owned by
Harness; stop that task on the computer when appropriate.

## Bound approvals

The Host advertises `quenderin.approvals.v1`. A local Gateway
`approval/request` receives a `quenderinBinding` only after the companion has
observed the session's actual workspace membership and open turn through the
local Gateway streams. The binding contains:

- Host/client device IDs, workspace/session IDs and `runId: "turn:<number>"`.
- The exact event ID and SHA-256 of the complete canonical JSON request.
- A fixed expiry at most 120 seconds after issue, enforced with a monotonic clock.

The native client sends `quenderin/approval` through the existing encrypted
`harness.remote.call` carrier, with `{args:{binding,clientId,outcome}}`. The Host
compares the complete binding against its pending record and consumes the record
**before** dispatching the original `$events/result` to its local Gateway. Both
Allow once and Deny require the same checks. Legacy remote `$events/result` is
blocked by this companion, so older clients must answer on the computer.

This Host configuration accepts only the native session carrier methods and
their fixed workspace/session/model endpoints. Alternate legacy API responders,
terminal commands, plugin management, file transfers, previews and other backend
RPCs are rejected. They require separately reviewed parity work before exposure.

Cancellation, a new turn, workspace removal/change, stream loss, disconnect,
expiry or a reused event ID cannot authorize another action. Missing authoritative
context leaves an approval visible but unavailable remotely. No response is
automatically retried after a lost acknowledgement. Host restart does not restore
approval capabilities. Quenderin must recover authoritative history and open new
streams; resolving an older pending request can require the computer.

This companion does not implement a durable Host command-deduplication service,
an agent spending cap, a terminal sandbox, or approval recovery across Host
restart. Native command journals prevent automatic mutation replay. These
remaining execution/recovery controls stay explicit in the delivery checklist.

The source-inspected Harness baseline is `dsh-v0.2.1-rc.1`, commit
`1600d8a1e140dcde43a1a0941940a0480712c011`. Its
[prompt handler](https://github.com/deepseek-ai/deepseek-harness/blob/1600d8a1e140dcde43a1a0941940a0480712c011/packages/api/session-controller/src/commands.ts#L319-L362)
returns `{accepted:true}` after admission, including sequential duplicate request
IDs. It checks pending inbox items and recorded user messages, so existing
persisted admission can be recognized after recovery. This is useful existing
support, not an atomic payload-bound reservation: concurrent admission and
acknowledgement-before-flush outcomes remain uncertain. Quenderin therefore keeps
automatic replay disabled. Source inspection is separate from the new isolated
official-runtime fixture, whose execution has not yet been verified.

## Verification

```sh
node --test native/remote-host/tests/*.test.mjs
```

Synthetic policy tests cover exact bindings, one-time consumption, expiry,
withdrawal, turn/workspace changes, revoked identities, unsafe public-policy files,
canonical action digests and bounds. `.github/workflows/remote-host.yml` applies
the exact source patch to a disposable pinned upstream checkout and compiles the
actual bundle plus Gateway tests. No fixture calls a model, uses an account key,
starts a relay or installs a plugin in a user's profile. Passing those checks
does not establish a live desktop/mobile journey.

The shared approval-digest fixtures include JavaScript numeric property ordering,
Unicode, slashes, negative zero and floating-point boundaries. Android currently
leaves approvals containing unsupported numeric magnitudes/exponents unavailable
remotely; the user can answer on the computer. It never substitutes a different
request or bypasses the digest check.
