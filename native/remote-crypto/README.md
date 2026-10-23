# DSH Remote crypto preparation

This isolated Rust facade implements the fixed DSH Remote v1 suite
`Noise_IK_25519_ChaChaPoly_SHA256` using maintained Snow primitives. It has no
network, persistence, relay, enrollment, provider, or native app activation.
Its complete lockfile is reviewed and the locked host checks pass at source
`e7baa288e898c823e0b83cab465682b25b67b27c` in
[run 39904655943](https://github.com/alikatgh/quenderin/actions/runs/39904655943).
Nine Rust tests, clippy and both actual generated-binding runtime probes pass.
Native app linking and platform validation remain separate release gates.

The synchronous UniFFI surface is deliberately narrow:

- `NoiseIkSession.create(role, localPrivateKey, enrolledRemotePublicKey,
  connectionId, hostDeviceId, clientDeviceId)`.
- `derivePublicKey(localPrivateKey)` returns only the corresponding public key
  for enrollment, using the maintained Snow DH provider. Private input generation
  and secure persistence belong to the native platform CSPRNG/vault.
- `initiate()` emits an empty initiator message 1 exactly once.
- `readHandshake(message)` authenticates the enrolled static key and rejects
  nonempty payloads before a response or transport state is created. Responders
  emit empty message 2 in `response`. It returns `complete = true` only after
  successful finalization. No application plaintext crosses the handshake API.
- `encrypt`, `decrypt`, `counters`, and idempotent `shutdown`.

`shutdown` closes protocol state while retaining a usable language wrapper that
returns a typed Closed error. Kotlin's generated `AutoCloseable.close()`/`use`
releases its object handle separately; Swift releases the wrapper through ARC.
Do not export a Rust method named `close`: it collides with UniFFI's generated
Kotlin lifecycle method. Call `shutdown` when ending a session and then release
the wrapper using its language's normal ownership rules.

There is no public nonce setter, private-key generator/export, split-key access,
deterministic entropy, caller-provided suite, or async task/callback. Generated
Swift/Kotlin source is obtained from the same locked host library metadata, not
handwritten to imitate generated bindings. Swift needs its generated C header
and module map; Kotlin needs the matching native library and JNA integration.
No such binaries or app linking are supplied by this milestone.

The exact UTF-8 prologue is
`DSH-REMOTE\0v=1\0connection=…\0host=…\0client=…`. Empty/NUL-containing fields and
fields over 1,024 UTF-8 bytes are rejected. Noise messages are limited to 65,535
bytes, including handshake overhead/AEAD tags. A mutex covers each complete
state/cipher/counter operation. Authentication/identity failures during handshake
close the session. Transport tag failures, including replay, return no plaintext
and do not advance counters; the next valid in-order frame remains readable.
This matches the pinned upstream wrapper's rejection/continuation behavior.
An exhausted counter closes the session before encryption/decryption.

All facade-owned private input and temporary plaintext buffers use `zeroize`.
Debug/error output contains no key, identity or payload values. Snow's default
X25519 provider is wrapped only to reject an all-zero shared result; no primitive
is implemented here. Snow 0.10 does **not** promise erasure of all its internal
DH/cipher/handshake copies, nor can UniFFI erase foreign-language caller copies.
Closing drops Snow state and clears facade-owned buffers; complete process-memory
erasure is not claimed. Callers must protect input lifetimes and shut down abandoned
sessions. A poisoned state lock fails closed.

## Source and fixture provenance

- [Snow v0.10.0](https://github.com/mcginty/snow/tree/4bb43f50370bdb3e8b1b57814ac662864db2704f),
  commit `4bb43f50370bdb3e8b1b57814ac662864db2704f`, Apache-2.0 OR MIT.
- [UniFFI v0.32.2](https://github.com/mozilla/uniffi-rs/tree/7bc621ee9d0d15371d792612707ba5ed4111f950),
  commit `7bc621ee9d0d15371d792612707ba5ed4111f950`, MPL-2.0.
- Rust toolchain 1.90.0. Third-party transitive dependency versions/checksums must
  be retained in the complete generated `Cargo.lock` before compilation.
- DSH Remote adapter at
  [`packages/crypto/src/noise.ts`](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/crypto/src/noise.ts)
  and golden test at
  [`packages/crypto/tests/noise-golden-vectors.test.ts`](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/crypto/tests/noise-golden-vectors.test.ts).
- External public **synthetic** test input:
  [`fixtures/crypto/v1/noise-ik.json`](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/fixtures/crypto/v1/noise-ik.json),
  Git blob `52e83a5de8444dbd13115ccd3d8131950907e302`, exactly 2,960 bytes.
  The root and crypto-package license coverage is unresolved (the inspected
  crypto package has no LICENSE). The MIT notice in the separate plugin package
  is not treated as repository-wide permission. No DSH implementation or fixture
  content is vendored. The bounded fetch verifies the immutable blob before use.

## Hosted verification and source generation

The path-limited/manual `.github/workflows/remote-crypto.yml` uses one public
standard Ubuntu job, read-only checkout with credentials removed, no artifact
uploads/cache/service provisioning, no retries, and a 15-minute timeout. It never
loads actual user keys or contacts a provider, Host, relay, or production endpoint.
Its upstream input fetches are pinned source/dependencies, the 2,960-byte public
synthetic fixture, and the hash-pinned host Kotlin compiler/JNA described below.

If `Cargo.lock` is absent, the first hosted run may only resolve metadata and
emit the complete lock between `BEGIN_QUENDERIN_REMOTE_CARGO_LOCK` and
`END_QUENDERIN_REMOTE_CARGO_LOCK`. It then fails intentionally before compiling.
Review and commit those exact bytes, then run again. All compilation/test/bindgen
commands require `--locked`. The workflow checks exact golden handshake bytes,
transport ciphertexts and both roles' counters; wrong peers/prologues, handshake
tampering, transport tamper/replay/continuation, invalid input, maximum frame
sizes, overflow and concurrent sends are also tested.
The upstream generic Noise golden vectors contain nonempty synthetic handshake
payloads. A private test-only adapter exercises those exact vectors through the
same state path; a separate public API contract test establishes empty production
handshakes and rejection of authenticated nonempty payloads before response.

The initial metadata-only [run 39902648510](https://github.com/alikatgh/quenderin/actions/runs/39902648510)
stopped at that gate as intended. Its complete 29,856-byte lock was independently
reviewed: 128 reachable packages, 117 checksummed crates.io packages, the pinned
Snow revision and nine matching UniFFI 0.32.2 Git packages, with no additional
sources. `Cargo.lock` SHA-256 is
`71e2581d368849cfc64242216cdc3cb5196ce9d5ba0e92c5430f2981641c6147`.
That provenance review permits the bounded locked host checks; it is not a
cryptographic test or native compatibility result.

After locked checks pass, generated Swift/Kotlin/header/module-map source is
emitted as bounded gzip/base64 log blocks with filename, byte count and SHA-256.
Before emitting it, the workflow compiles the actual generated Kotlin with the
existing Kotlin 2.0.21 pin and JNA 5.19.1 (SHA-256
`4fb141dd8ef6b0585ffceea4bc49602fbc6312fa977e2c488794ea3e6aafecae`), and the
actual generated Swift/header/module map with the runner's included Linux Swift
compiler. Both host probes call the same built `.so` for both-role empty IK,
bidirectional encryption, counters, typed errors, tamper/replay continuation,
shutdown and language-wrapper disposal. No generated template is patched to
make a probe pass. Missing included Swift/JDK tools stop the workflow before
downloads/builds; there is no Swift/JDK installation or substituted fake binding.

The next linked probes compile the production native secure-link, fragment and
business-coordinator sources with those actual generated bindings. A test-only
in-memory peer uses the same Rust library as responder: synchronous empty
96/48-byte handshakes, a fragmented describe response and 60 KiB prompt, exact
business bytes/counters and correlated completions. Fresh sessions exercise real
handshake/tag tampering and require queues, partial assemblies and both language
wrappers to retire. Test keys are generated in memory from OS-backed randomness;
only fixed pass/fail messages are printed. No provider, relay or actual Host is
contacted. Each linked compile is capped at 180 seconds and each process at 30
seconds within the unchanged 15-minute job. Relevant production source paths
also trigger this integration gate.

The Swift dependency closure uses the unchanged common privacy protocol/defaults
extracted into `NativeConnectionPrivateValue.swift`; concrete domain conformances
stay in their original file. No production models or bindings are stubbed. Local
Kotlin type compilation (installed 2.4.0), Swift parsing and existing Python guards
pass. At source `f91b138a0d27fa0e4abb70969e55716c6a21240c`,
[run 39911672366](https://github.com/alikatgh/quenderin/actions/runs/39911672366)
passes all nine Rust tests, clippy, both original generated-binding probes and
both linked probes with pinned Kotlin 2.0.21 and Linux Swift. The success markers
are `NATIVE_LINKED_HARNESS_PASS kotlin` and `NATIVE_LINKED_HARNESS_PASS swift`.
That run uses the typed in-memory packet seam. At Control JSON source
`6ef4362a603fed34e3a025bd5246a5d3314248c0`,
[run 39914626417](https://github.com/alikatgh/quenderin/actions/runs/39914626417)
passes those same gates with every handshake/relay packet serialized and parsed
through the native JSON codec in both directions. Real platform artifacts,
network delivery and enrollment remain separate gates.

Review, decode and retain those sources before integrating native consumers.
These Linux host checks are not platform binary compatibility or Apple SDK checks.
iOS 16.4/macOS 13.3, Android API 28, Android ABI/16 KiB alignment, matching UniFFI
runtime dependencies, app linking and signed-device behavior remain unverified.
No local native build, simulator/device run, model download, or real credential
was used to prepare this source.
