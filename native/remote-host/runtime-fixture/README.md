# Official Harness runtime fixture

This is a separate, test-only package for DeepSeek Harness `0.2.1-rc.1` from
[`1600d8a1e140dcde43a1a0941940a0480712c011`](https://github.com/deepseek-ai/deepseek-harness/tree/1600d8a1e140dcde43a1a0941940a0480712c011).
It does not reuse the older mixed dependency closure in the remote plugin's
pnpm lock. `package-lock.json` pins the complete npm closure and
`dependency-provenance.json` inventories every resolved URL, integrity, license
and lifecycle-script marker. `registry-metadata.json` records exact-version
manifest comparisons for all 220 unique package artifacts (238 dependency
entries). Direct dependencies use exact versions. The official Harness package
manifests identify its source repository but supply no `gitHead` or npm build
attestation; an exact artifact-to-source-commit attestation is not established.

The first official Gateway/Agent/tool/approval journey **passed** at source
`8f3081` in the [hosted Host job](https://github.com/alikatgh/quenderin/actions/runs/39986442942/job/120526738753).
Its 47 frames before teardown and source provenance were captured separately;
this increment does not replace those frozen facts. Both the original journey
and stop/cold-history/sequential-dedup test **pass** at final source `85e38aa`
in the [final hosted run](https://github.com/alikatgh/quenderin/actions/runs/39998547148).
The existing public Ubuntu [Host workflow](../../../.github/workflows/remote-host.yml)
runs lock/guard, bootstrap and disconnected runtime steps after patched Host
compilation and synthetic Gateway tests. Build or synthetic bridge success
alone does not establish an official runtime journey.

## Exercised path

The official testkit mounts the real LLM/session/projection/tool/Agent services
and production AgentLoop. This fixture additionally mounts production JSONL
persistence, JSON domain storage, WorkspaceRegistry, SessionController,
WorkspaceController, ApprovalService, Commands, FileUploads, TypertRegistry,
Gateway and API Remotes. Published generated `./typert` contributions register
the strict production Host descriptors.

An in-process owner Peer supplies the authenticated transport boundary. The
**upstream** `TypertGatewaySwitch.local(peer)` adapts the **real** Gateway; the
patched production `HarnessRemoteBridge` consumes that adapter. No fake
`LocalTypertGateway`, Remote event source, controller or Agent loop is used.

The journey opens `workspace/follow`, registers a temporary Workspace through
the Host-side real Gateway, creates/lists a Session through the native bridge,
opens `session/follow`, `session/control` and `$events`, then sends the native
`{args:{request:{sessionId,requestId,mode,content}}}` prompt payload. The real
loop consumes four synthetic model chunks containing one inert tool call. The
production pre-execute/approval services generate an approval waterfall, API
Remotes forwards it, and the companion binds it to the observed Workspace,
Session, turn and client. One `quenderin/approval` result allows one inert tool
execution; duplicate approval consumption must fail. Four further synthetic
chunks complete the real turn. The test asserts the `{accepted:true}` admission
receipt, live user-message event identity, approval audit pair and completed
turn. That first passing test does not flush and cold-read its message.

## Stop and persisted-history gate — hosted passed

One additional test mounts the same real service stack in its own temporary
storage. A single model call emits two partial-text chunks, then waits on its
production cancellation signal. `session/cancel` must return the real admission
receipt; a subsequent streamed `turn/end` with user-aborted reason and an idle
Agent must confirm the stop. The receipt alone is insufficient. The test then
closes the business streams and Peer, opens a fresh Peer/bridge with real
Workspace/history/control/event streams, and reconciles the completed log and
absence of an active assistant attempt from their authoritative baselines.

After `sessionPersistence.flush()` and full Context disposal, a fresh Context
opens the same JSONL/domain storage. A real `session/page` must cold-read the
original user-message `rpcId` once and the same aborted end, without activating
an Agent. A sequential repeat of the exact original prompt then resumes the
Session and must return `{accepted:true}` without another model call, tool
execution, user-message occurrence or turn. The production prompt handler's
persisted `rpcId` check owns that behavior; the fixture implements no command
deduplication service.

The warm recovery adapter permits one model call/two chunks; the cold adapter
permits zero calls. Recovery allows zero tool attempts. This is a clean Context
restart in one disconnected test process, not a process crash, rollback,
concurrent exactly-once guarantee, relay reconnect or native-device journey.
The linked final hosted run passes this gate. The first test remains the
sole canonical-facts writer with two model calls and one inert tool execution;
the new test prints a bounded status/failure summary and never overwrites its
captured facts.

The credential-free adapter is the sole model boundary. Text-only attachment
storage rejects all media and inherits the production text admission method.
The SessionQueryEngine subclass inherits the real exact-read/list logic and
rejects full-text search. The official carrier-neutral HostConnectionService
uses a reject-all browser-auth object: HTTP/auth is never mounted or called.
Those auxiliary boundaries do not claim media, search, authentication, network,
relay, Noise, provider-inference or device coverage. No provider plugin,
credential store, account or external service is configured.

## Review before executing packages

Only metadata resolution and small source/declaration artifact inspection are
needed locally. Never run `npm ci` locally for this fixture.

```sh
cd native/remote-host/runtime-fixture
node tools/check-lock.mjs
```

Review the complete lock, both provenance inventories and fixture source. Confirm
public npm package provenance/source and `sha512` integrity before accepting
the reported full-lock SHA256. Bootstrap requires that exact hash as an
explicit argument and a hosted Node 22 runner. It stops before dependency
imports or package execution if the hash is missing, stale or malformed.
`npm ci --ignore-scripts` pins installation and disables every lifecycle hook;
the lock records hooks in esbuild, fsevents and koffi for review. fsevents is
optional and platform restricted. This test exercises neither native openers
nor desktop file handoffs. The exact locked JSONL artifact's Linux
`SessionWriteLease` uses the prebuilt Node-API `node-addon-system/flock`
binding; its Windows lease branch dynamically loads Koffi/kernel32. This is
not a native-free runtime test. The hosted runner needs that prebuilt native
lock package and esbuild's platform package for Vitest's ordinary TypeScript
transformation; no native application build runs.

## Smallest hosted integration

Use the existing exact-revision upstream checkout prepared by
`../tools/prepare_host.py --apply`. Run this as a separate step after source and
lock review; do not install this closure in the upstream workspace. Node 22
and Ubuntu 24.04 suffice. `REVIEWED_SHA256` below is a review result, not an
authorization bypass or a value automatically derived by the install script.
The source guard checks every pinned `packages/*/src` file and package/root
package or TypeScript manifest, permits only the four exact production source
patches and two exact policy additions, and rejects extra source, symlinks or
manifest changes. It checks the fixture's four Vite source aliases and follows
their static/literal import closure inside those verified roots. The current
closure is 17 upstream source modules plus the policy module; other runtime
imports are Node builtins or the fixture's locked packages. Rebuilt `dist`
files are not imported by these aliases and are intentionally outside this
source check. User/system Git config and Git replacement objects are disabled.

```sh
cd native/remote-host/runtime-fixture
env -i GITHUB_ACTIONS=true PATH="$PATH" node tools/bootstrap.mjs "$REVIEWED_SHA256"
fixture_parent_netns="$(readlink /proc/self/ns/net)"
sudo -n unshare --net -- setpriv \
  --reuid "$(id -u)" --regid "$(id -g)" --clear-groups \
  --bounding-set=-all --inh-caps=-all --ambient-caps=-all --no-new-privs \
  -- env -i \
  GITHUB_ACTIONS=true \
  QUENDERIN_PARENT_NETNS="$fixture_parent_netns" \
  QUENDERIN_HOST_SOURCE="$GITHUB_WORKSPACE/upstream" \
  PATH="$PATH" \
  node tools/run.mjs "$REVIEWED_SHA256"
```

Bootstrap sends TERM by 179 seconds, then forcibly kills its POSIX process
group after 250 ms; pipe cleanup has a further 100 ms cutoff. The runtime's
30-second budget includes its source verification: the fixture group receives
TERM by 29 seconds from runner start, with the same KILL/pipe cutoff. One test
stays under 10 seconds; both tests share the unchanged runtime process budget.
Each condition waits at most 1.5 seconds. Across the suite, the adapters permit
three model calls/ten chunks and one inert tool execution. The first journey
allows two calls/eight chunks/one tool; recovery allows one stalled call/two
chunks/zero tools, including zero cold-context calls. Each test captures at most
128 frames of 48 KiB per frame. The first test's canonical output is capped at
256 KiB total. A fresh temporary root holds
every Session, Workspace and domain artifact; the runner removes it in
`finally`. No input comes from a user's home or projects. The trusted workflow
shell captures its own Linux network namespace before `sudo`/`unshare` and
passes that nonsecret `net:[digits]` baseline only to the supervisor. The new
namespace is created under `sudo`, then `setpriv` drops to the original runner
UID/GID, clears supplementary groups and every bounding, inheritable and
ambient capability, and enables no-new-privileges before Node starts. Before
loading package code, the runner requires nonroot real/effective/saved/fs UIDs,
zero effective/permitted/bounding/inheritable/ambient capabilities,
`NoNewPrivs: 1`, a valid current namespace different from the captured parent,
and loopback-only interfaces and routes. It reads only `/proc/self/ns/net`;
access to a privileged process's namespace is unnecessary. The parent baseline
is not inherited by the fixture child. Dependencies cannot use `sudo` or retained capabilities to rejoin the
parent namespace. If `sudo`/`unshare`/`setpriv` is unavailable or any guard
fails, this check is blocked; do not weaken it to a promise or monkeypatch.
The async supervisor enforces time and aggregate output limits on ordinary
POSIX process groups, including TERM-ignoring children and grandchildren. It
is not an adversarial cgroup/process sandbox: deliberate new-session/process
group escape needs OS-level containment. The workflow's overall timeout is an
additional boundary.

The runtime child receives an explicit environment allowlist: the Node/system
tool PATH, fixed locale/timezone/CI flags and the fixture's temporary/source
paths. Caller `HOME`, XDG, `NODE_OPTIONS`, Codex and provider credential
variables are not inherited. Global `HOME`/`CODEX_HOME` are not repurposed.
`DSH_HOME` and `TMPDIR`, plus the JSON/domain/persistence/Workspace options,
point at private fixture scratch; no credential provider or profile-scanning
plugin is mounted. The browser event host's `homedir()` value is account
metadata, canonicalized in emitted facts, and does not read profile files.
Bootstrap also receives a narrow environment, disables user/global npm config,
and keeps its cache/prefix/temp files in newly owned disposable install scratch.

The runner emits at most 256 KiB of canonical synthetic facts between
`QUENDERIN_OFFICIAL_RUNTIME_FACTS_BEGIN` / `END` markers in CI logs after a
**passing** run. Child diagnostics are limited to 32 KiB per output stream,
with a 1 MiB subprocess buffer ceiling. The JSON contains bounded observed
production DTOs/frame envelopes with canonical synthetic identities, temporary
paths and times. Its exclusively created file exists only inside runner-owned
ephemeral scratch, which is removed before the runner exits. Do not add
artifact or cache uploads for this fixture. Passing CI log facts may inform
native parser fixtures after review; hand-authored examples are not runtime
evidence. Stop, reopened-stream, flush/cold-read and sequential persisted-duplicate
checks pass in the linked final run. Process-crash recovery, lost
acknowledgements, concurrent admission and live relay/native interoperability
remain separate unverified behavior.

## Guard-only checks

These run built-in Node children and tiny disposable fake Git checkouts;
they install or execute no dependency packages and run no native builds.
Supply a registered session scratch parent for the Python cases.

```sh
node --test tools/guard.test.mjs
QUENDERIN_GUARD_SCRATCH=/absolute/registered/scratch python3 -B tools/check_host_test.py
```

Checks cover the environment allowlist, privilege rejection, a child and
grandchild that both ignore TERM, output flooding, dirty switch/protocol and
transitive source, source shadowing/symlinks, changed/extra manifests, and
allowance for rebuilt unimported `dist`.

## Attribution

The service mounting and synthetic `StreamChunk` patterns are adapted from
DeepSeek's maintained MIT test fixtures at the pinned revision:

- [`agent-loop-testkit`](https://github.com/deepseek-ai/deepseek-harness/blob/1600d8a1e140dcde43a1a0941940a0480712c011/packages/test-support/agent-loop-testkit/src/index.ts)
- [`SDK credential-free adapter`](https://github.com/deepseek-ai/deepseek-harness/blob/1600d8a1e140dcde43a1a0941940a0480712c011/packages/sdk/server/tests/server.spec.ts)
- [`scripted chunks`](https://github.com/deepseek-ai/deepseek-harness/blob/1600d8a1e140dcde43a1a0941940a0480712c011/packages/core/agent-loop/tests/mock-adapter.ts)
- [`Session access fixtures`](https://github.com/deepseek-ai/deepseek-harness/blob/1600d8a1e140dcde43a1a0941940a0480712c011/packages/api/session-controller/tests/remote-access.host.spec.ts)

See [LICENSE.DeepSeek](LICENSE.DeepSeek), copyright (c) 2026 DeepSeek. The
patched remote bridge/switch remain the existing pinned MIT upstream source
at `9a60e783ec1ceaff6116b0462a2863f07f602a55`; their notice is
[../LICENSE.upstream](../LICENSE.upstream). No third-party implementation is
vendored into this package.
