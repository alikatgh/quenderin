# DSH Remote crypto preparation

This isolated Rust facade implements the fixed DSH Remote v1 suite
`Noise_IK_25519_ChaChaPoly_SHA256` using maintained Snow primitives. It has no
network, persistence, relay, enrollment, provider, or native app activation.
It is not release-ready until its complete lockfile is reviewed and the locked
host checks pass. Native linking and platform validation are separate work.

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
- `encrypt`, `decrypt`, `counters`, and idempotent `close`.

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
erasure is not claimed. Callers must protect input lifetimes and close abandoned
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
Its only upstream input fetches are pinned source/dependency metadata and the
2,960-byte public synthetic fixture.

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
Review, decode and retain those sources before integrating native consumers.
The generated files are not themselves a platform binary compatibility check.
iOS 16.4/macOS 13.3, Android API 28, Android ABI/16 KiB alignment, matching UniFFI
runtime dependencies, app linking and signed-device behavior remain unverified.
No local native build, simulator/device run, model download, or real credential
was used to prepare this source.
