# Release & store submission

The signing, build and console path for native app updates. Never add credentials
to this record or create new credential files. Use the established project wrapper
or already-authorized signing configuration. A debug build is not a signed store release.

## 23 October 2026 — native DeepSeek source preparation

The reviewed `codex/native-connections-20261023` change adds a separate native DeepSeek
destination before local model setup and in the existing Apple/Android shell.
The delivery checklist is [native-connections-roadmap.md](native-connections-roadmap.md).
This is source preparation, not an uploaded or submitted app version. Store
versions/counters and review states below remain dated evidence until refreshed.

[PR #170](https://github.com/alikatgh/quenderin/pull/170) merged as
`3c096da43fcb6414655946f41476647bf8da3b78`. Its exact feature source
`4abdd1f1794d1fe9e732d2737acc410a2fb7c9a6` passed
[all 18 CI jobs](https://github.com/alikatgh/quenderin/actions/runs/39899498601)
and the separate secret scan. This includes 644 Swift tests (six skipped), all
104 connection and 30 DeepSeek fixture executions, Android core/APK/unsigned AAB,
iOS SDK compilation and desktop packaging. Independent source review findings
were resolved before merge. No signed store artifact or native interaction result
is established by this source merge.

The direct API route uses the user's DeepSeek account and the fixed official
origin. Setup validates `/models`; each explicit Send starts one streaming Chat
Completions request. Tools, files, images, search/fetch, autonomous runs and funded
Quenderin services are not enabled by this increment. Provider account billing
limits have not been inspected; the application limits are not a financial cap.
Development checks use synthetic transports/keys and make no live inference calls.

Affected release risks and controls:

- **External work/cost:** one request per Send, one active run per session,
  120-second deadline, 4,096 output-token ceiling, no automatic retries or loops.
  Cancellation is scoped to the exact call; relaunch does not replay a request.
  These are application bounds. Any funded live validation/activation still needs
  the applicable approved allowance and verified provider-enforced maximum.
- **Resource exhaustion:** 8 MiB request/response, 1 MiB event/text and 65,536
  streaming-event bounds; limited local history (Apple 50 chats within one 8 MiB
  journal; Android 30 separately bounded chats). Exhaustion retains existing data
  and rejects new work. No model downloads are added to this route.
- **Credentials/privacy:** Apple Keychain and Android Keystore-backed encrypted
  storage; opaque references in profiles, isolated TLS transports, redirects and
  cookies/cache disabled, fixed redacted error messages. Android credentials are
  excluded from backup/transfer. Local conversations are not read by this route.
- **Integrity/recovery:** atomic local journal writes; unfinished turns remain
  visibly incomplete and cannot silently become later provider history. Failed
  initial reads stop new writes. Credential replacement/removal preserves durable
  ownership and fails closed. Opening cloud UI preserves the local shell/drafts.
- **Verification/publication:** shared request/SSE/model fixtures and strict
  native execution-marker guards supplement transport/controller failure tests.
  Fresh independent review covers the integrated source. No signing workflow,
  store submission, hosted relay or website deployment is triggered by this task
  branch. Existing PR checks use the established bounded public CI route.

The root dependency audit blocker was repaired with compatible Electron,
Vite/Vitest updates; a fresh local audit reports zero vulnerabilities. Compatible
UI updates pass 27 tests and a production bundle build, but its separate audit
still reports 5 high/2 moderate findings in the Tailwind 3 glob/braces chain and
selector parser. A Tailwind migration needs its own rendered verification.

Before any native store submission, refresh
the exact release source and store state, validate the signed Keychain/Keystore
and changed native journeys through an authorized route, update privacy/store
disclosures for direct third-party AI transmission, and resolve applicable policy
and release gates. The current prohibition on simulator/device runs leaves
rendered native interaction unverified. No source/test result substitutes for it.

## 23 October 2026 — remote Harness source preparation

The next source increment isolates the pinned V3 decrypted business carrier in
both native cores. Shared request/frame fixtures cover current RPCs, opaque
results, stream acknowledgements and strict contextual numbers. Fake coordinators
bound pending requests, deadlines and Host stream reservations; stale callbacks
cannot retire newer connections. Lost mutation acknowledgements remain unknown
and are never replayed. Both approval decisions fail closed until a negotiated
Host extension binds device/workspace/run/action/expiry.

This source does not connect to a Host. Enrollment, relay/WebSocket framing,
durable journal integration, native session UI and real Host verification remain
pending. [PR #171](https://github.com/alikatgh/quenderin/pull/171) merged as
`94ee6e0766081d3fbf75b4cdb5423e6d8e84b0f5`. Its exact source
`e7baa288e898c823e0b83cab465682b25b67b27c` passed all 18 CI jobs and the
separate secret scan. The isolated Rust Noise facade uses exact Snow/UniFFI pins
and an independently reviewed complete lock. Its bounded public Ubuntu
[host run](https://github.com/alikatgh/quenderin/actions/runs/39904655943) passes
nine Rust tests, clippy and actual generated Kotlin/JNA and Swift runtime probes
against the same library, including empty authenticated handshakes, transport,
tamper/replay continuation, errors and shutdown. The exported `shutdown` method
avoids collision with generated Kotlin wrapper disposal. No credentials,
provider/relay services, caches or artifact uploads are used. Platform native
linking/ABI checks, secure identity storage and export-compliance review remain
gates before encrypted remote release.

The next source increment implements DSHF plaintext fragmentation in both native
cores using 48 original shared fixtures. It bounds messages to 4 MiB, incomplete
assemblies to eight/8 MiB aggregate, lifetime to 120 seconds and used identifiers
to 4,096 per authenticated generation. Invalid active-generation input retires
the layer; stale-generation callbacks cannot retire a replacement. Kotlin runs
all 48 cases; exact-marker validation, 13 Python tests, Swift parsing and fresh
independent review pass. Hosted Swift and Android core checks at
`a4e6ec678a7a4f7a9bd0464bb6bb5e893bef60e6` execute all 48 cases exactly
once. The Swift suite runs 669 tests, six skipped, no failures. No network,
enrollment, identity generation or app activation is added by this layer.

A further source increment supplies the secure-link owner around injected Noise
and decoded packet ports. It bounds handshake time, counters and queued message
work, checks exact UTF-8 identity binding, serializes complete fragment batches,
and blocks replacement after failed transport cleanup. Kotlin requires the same
owner thread for link/coordinator interactions; its regression reproduces the
previous monitor inversion and proves off-thread rejection breaks that cycle.
All 28 original Kotlin host scenarios, 17 Python evidence-guard tests, Swift
parsing and fresh independent review pass after the fixes. Hosted Swift
compilation/XCTest remains pending. Fake-provider behavior is not evidence of
maintained Rust linkage, encrypted network interoperability, durable trust,
native interaction or signed release readiness.

## 23 October 2026 — Android unsigned export source gate

The existing manual-only `android-beta-candidate.yml` now requires four explicit
inputs: `source_commit` (lowercase full 40-character SHA), `draft_release_id`,
`version_name` (numeric major.minor.patch), and positive `version_code`. Dispatch
must use `main` in the public owner repository. Before candidate checkout or
building, the reviewed exporter requires a commit reachable from the checkout-time
`origin/main` snapshot,
matching committed Android package/version/code, and an existing unpublished
prerelease draft whose `target_commitish` is that exact SHA. The tag must be
`android-beta-<version_name>-candidate-<first-seven-SHA-characters>`; the three
asset names include version, code and the same source prefix. A new source needs
its own matching precreated draft; the October 20 draft and its assets remain
historical evidence and cannot be relabelled or replaced.

Source/draft gates repeat before export. Google's unmodified Apache-2.0
[bundletool 1.18.3](https://github.com/google/bundletool/releases/tag/1.18.3) checks
the actual AAB manifest package/version/code before staging; the receipt records
that metadata and the pinned tool digest. Its host-only HTTPS download has no
retry, a 120-second limit and an exact 32,520,401-byte ceiling, with size/SHA-256
verification before execution. The existing single 40-minute Ubuntu job,
512 MiB AAB ceiling, three-file export and no-overwrite rules remain. Synthetic
preflight/export tests cover rejected inputs, off-main source, old/mismatched
drafts, changed source, packaged metadata mismatch and upload collisions. No
workflow run, new draft, signing operation or Play upload is established by this
source repair; upload-key recovery and native interaction gaps remain above.

Independent source review and all 29 no-network fixtures pass. A separate host
inspection used that exact hash-verified Google JAR against the retained October
20 unsigned AAB (existing SHA-256 `5c40d38862aacd84d7c8aabdff983fb5ed7ca91b6357c4fbc2479c93837dc8da`).
Its real manifest matches `ai.quenderin.app`, `0.5.0`, code `5`; intentionally
expecting `0.5.1`/code `6` fails before staging/upload. The original AAB was read
without modification. This validates the packaged-metadata check against a
historical artifact, not a newly exported candidate or a Play submission.

## 20 October 2026 — Android Alpha recovery and bundle export

The live Quenderin App signing page still registers upload SHA-256
`8B:38:F4:E5:85:88:3A:B7:37:F2:91:8F:49:90:BA:40:17:67:A0:39:37:EB:2A:68:72:88:BD:E3:E9:49:CF:3D`.
The existing Alpha draft, release ID **2**, retains name **5 (0.5.0)** and its
English notes. No new bundle is attached; the previous **2 (0.2.0)** is excluded
from that draft. Do not include the old bundle to present it as the new version.

With explicit user authorization, seven previously unresolved release stores were
opened using each store's own existing signing properties. All seven saved
passwords authenticated, each store exposed one public certificate, and **none
matched Quenderin**. Four distinct SDK debug stores also authenticated without a
match. The separately checked user-referenced PKCS12 contained one other-app
certificate and no Quenderin certificate. One remaining generic encrypted store
has no established credential source and is **not ruled out**. Existing Keychain
public certificates and Quenderin-labelled credential metadata yielded no match;
no second local home or mounted external backup was available. These observations
do not establish that the original Quenderin key is lost. No private key was
exported, generated or reset. Reuse these results instead of repeating the same
password checks or asking for credential contents.

The user then directed recovery to the macOS keys application. An escalated,
attributes-only Keychain key search found no accessible label/tag match or public
key identifier matching the verified Play upload certificate. This is limited to
the current process's keychain search list and access groups. Native app control
failed before Keychain Access or Passwords opened; the Passwords vault's UI is
**not verified**. The pending human step is a Passwords search for Quenderin,
offgrid or alias_name and its non-secret entry title/path, not a credential value.

CI 39201633327 built the candidate but retained no downloadable AAB. A dedicated
**draft**, [Android 0.5.0 unsigned build export](https://github.com/alikatgh/quenderin/releases/tag/untagged-3afab393fd54dd936274),
ID **418062490**, targets exact app source
`eecf089ff328f7303a7d4a64358252e8913e32f5`.
[Export run 39380404019](https://github.com/alikatgh/quenderin/actions/runs/39380404019)
**passed** from workflow revision `3143e514771d79b1cd0cb893d2907a9274e5b2b8`.
The draft retains the **35,187,551-byte unsigned AAB**, checksum and provenance
receipt. SHA-256 is
`5c40d38862aacd84d7c8aabdff983fb5ed7ca91b6357c4fbc2479c93837dc8da`.
Real Prism JNI compilation, both image DSO pairs, dependency closure, 16 KiB
alignment, private backup/localization fixtures and core tests all passed. The
receipt agrees with GitHub's asset digest and exact source/version; its downloaded
bytes also match GitHub's receipt digest. The initial local fetch failed with
ENOSPC and only its incomplete file was removed. After measured headroom recovered,
all three assets downloaded successfully and matched their server digests. The
actual AAB passed unsigned ZIP/CRC/required-JNI structure checks locally. Retained
files are in canonical `android/app/build/outputs/verified-beta-0.5.0-5-eecf089/`.
This draft is neither a signed bundle nor a Play release. The export
uses standard public-repository Ubuntu compute and included Release binary
storage, with no Actions artifacts, persistent cache, Packages or LFS. This free
route avoids private billing access. Intended bounds are one job, 40 minutes,
three exported files, an AAB ceiling of 512 MiB and no automatic retries or asset
replacement. [Evidence](releases/2026-10-20-android-beta/preparation.json).

The Play Data safety form's previous **No collection/sharing** answer was reviewed
against optional Step 5. Updated answers are saved **as a draft**, not sent for
review: **Messages / Other in-app messages**, optional collection for app
functionality, no ephemeral-retention assertion, and no remote-deletion claim.
The user-initiated sharing exception is based on the initially unchecked consent,
visible host destination and explicit Send action. Remote origins require HTTPS;
plain HTTP is restricted to literal loopback. The console preview shows encrypted
transit and `https://quenderin.org/privacy`. Submit the declaration with the new
binary rather than representing its draft as a published update.

## Store browser profiles — verified 19 October 2026

| Service | Chrome profile |
|---|---|
| App Store Connect and Xcode Cloud | **Apple Developer** |
| Google Play Console | **Albert - Main - CMax** |
| Cloudflare publishing | **Albert - Main - CMax** (user-approved) |

Confirm the profile name and reuse the existing signed-in tab before store work.
Browser and tab IDs change between sessions; do not save an ID as the account
mapping. Do not open Play Console in Apple Developer: that profile's Google
account does not establish access to the registered Play developer. Reuse these
known profiles instead of starting new sign-in or account/terms setup flows.
Store-console access and access to the private Android upload key are separate
prerequisites; a public certificate is not a recovered private key.

## 19 October 2026 — native 0.5.0 submissions

- **iOS and macOS:** both **0.5.0 (22) Waiting for Review**, submitted on
  19 October with **Automatically release this version** selected. Public 0.4.0
  remains separate from the pending update. [iOS submission](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/3df425d2-02fa-47d1-a257-515b76f6e3c3)
  and [Mac submission](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/93d5cd80-87d5-4df6-ac28-53277255116f).
- **Exact release source:** `53994b799eb021bed10e2b58a727539283f02559`.
  [CI 39201633327](https://github.com/alikatgh/quenderin/actions/runs/39201633327)
  passed **all 18 jobs**, including the actual Android APK/unsigned AAB package
  checks, Apple runtime/SDK compilation and desktop package checks. Documentation
  recorded afterward does not alter the signed release source.
- **Signed Apple artifacts:** [Cloud build 22](https://appstoreconnect.apple.com/teams/f68608a6-96f8-4330-b123-b99c104eec71/xcode-cloud/products/4F96019F-D3C2-4ECE-AA57-12D901AC24A3/builds/cd511bc1-d650-405b-99d4-44a106bee5cd/summary)
  succeeded for iOS and universal macOS. The actual signed exports passed runtime,
  payload, signature and deployment-metadata gates, then both completed App Store
  Connect processing. Build 22 is selected in both submitted versions.
- **Existing Cloud workflow:** `Bonsai 2 App Store` still uses Prism and its
  iOS/macOS Archive actions. A manual-only start condition permits exactly
  `codex/native-050-20261019`; automatic pushes still target the old Bonsai branch.
  Before build 22, the included 25-hour plan showed 4h36 used / 20h24 available,
  resetting October 28 at 15:02 local. No plan change or paid upgrade was made.
- **Packaging defects repaired:** Cloud 20's Mac export synchronized the image
  framework build number to the app. The verifier now permits exactly that signed
  Mac case while keeping source identity, payload and signature checks strict.
  Cloud 21 passed that gate, and its Mac build processed successfully. Its iOS
  upload failed Apple processing with **90208 / 90360 / 90530**, because CMake's
  stock framework plist omitted `MinimumOSVersion`. The target-aware template now
  supplies minimum OS and supported platform; the verifier checks every Mach-O
  architecture and the app's deployment minimum. Forty Apple host fixtures pass,
  including malformed/missing metadata, wrong platform, mismatched slice minima,
  signature/payload tampering and the exact signed Mac exception. Independent
  review caught and resolved an older-CMake template-variable incompatibility.
  Twenty-three desktop diffusion fixtures also pass.
  [Cloud 20 artifact evidence](releases/2026-10-19-native-050/xcode-cloud-20-image-framework-evidence.json).
- **Google Play:** highest uploaded code remains **2 (0.2.0)**, at 100% on
  **Closed testing – Alpha**, with seven opted-in testers and production access
  unavailable. Source **0.5.0 / code 5** and hosted unsigned AAB compilation are
  prepared. The registered private upload key is still required: canonical
  `android/keystore.properties` is absent and no repository signing secret is
  configured. Console access and the public upload certificate do not provide
  that private key. No replacement key, reset or Play upload was performed.
- **Privacy and private storage:** native copy, canonical translations and the
  policy distinguish local inference from optional Step 5 transmission to the
  user's configured CUDA host. The host controls its retained copies. Apple
  system backups remain user-controlled; Android excludes approved memories from
  legacy backup, cloud backup and device transfer. Eight focused backup/resource
  fixtures pass, including negative exclusions and preservation of unmanaged
  Android translations. Canonical localization regeneration is deterministic.
- **Privacy page live:** [quenderin.org/privacy](https://quenderin.org/privacy)
  is deployed as Worker version `84a87b78-310e-4ecf-86fe-ad259374d6cb` at 100%.
  Exact existing Worker modules, runtime configuration, ASSETS binding, domain
  and subdomain settings were preserved. Only `/privacy.html` needed uploading;
  live policy/home/detail hashes and security headers passed. The existing model
  API returned JSON successfully. The user approved the official CLI's Account
  Read, Workers Scripts Write and mandatory Background Access permissions on
  Main - CMax. [Publication evidence](releases/2026-10-19-native-050/privacy-deployment.json).
- **Validation limits:** no local weights, local native builds, simulator runs or
  physical-device runs were performed. Full-weight inference, image quality,
  measured peak memory/speed and rendered native journeys remain unverified.
  Submission is not Apple approval or public availability. Android remains
  unsigned for store distribution. Windows/Linux distribution is separate.

The Mac source preserves its quit-on-last-window-close lifecycle and prior native
teardown remedy. Settings-only/window recovery in a signed candidate has not been
rendered under this update's explicit no-device-run constraint.

## October 18 source candidate — not a store release

[PR 163](https://github.com/alikatgh/quenderin/pull/163) expands the shared text
catalog to **28 entries** in TypeScript, Swift and Kotlin. The candidate includes
the runtime, complete-artifact installation and publisher chat adapters for Beam
and Muse on native Apple, Android and desktop. Beam requires all four parts
(**133,885,310,500 bytes**) and a 160 GiB whole-model memory floor; context and
working buffers may need more. Muse requires all 22 parts (**304,080,474,208
bytes**). A small metadata entry point is never treated as a complete model.

Dedicated app workflows now cover these additional releases:

- **Still-image questions:** managed model/projector pairs for MiniCPM-V 4.7 1B,
  MiniCPM-V 4.7 35B-A3B and Nemotron 3.5 Super VL 120B-A12B, with respective
  8/32/96 GiB available-memory floors. Native and desktop clients accept one
  bounded JPEG/PNG; video, audio and tools are unavailable.
- **Hy-Memory proposals:** separate native and desktop installation and inference,
  using the pinned community conversion, official no-thinking prompt and strict
  JSON validation. Only explicitly selected proposals enter a private approved
  memory store. No automatic conversation hook or generic chat path is enabled.
- **Granite Switch 4.1 8B:** an offline converter verifies the official checkpoint
  already on disk and creates a new GGUF plus conversion receipt. Native and
  desktop import/chat adapters verify that pair before loading. The receipt is
  conversion evidence, not a publisher signature or inference result. Speech,
  decision and guardian modes are not enabled.
- **Step 5 Preview:** native and desktop text clients connect, after explicit
  consent, to the user's existing CUDA host through the pinned official backend
  and Quenderin gateway. This is a remote specialist, not on-phone inference or
  automatic server provisioning.
- **Images:** isolated FLUX 3 Image Klein and MOSS Image Base/SFT workflows use
  three complete component presets and a 24 GiB available-memory floor. Gated
  FLUX files require the user's publisher access and license decision. Native
  import/install and desktop prepared-folder verification are explicit actions.

Nemotron Bolt E4B remains unavailable because no exact public artifact has been
verified. See [the model integration record](bonsai-2.md) for pinned sources,
resource limits, conversion commands and workflow boundaries.

Ordinary and specialist engines share an exclusive resource lease. The app
joins ordinary work and unloads idle text weights before measuring memory for a
specialist; selection and conversation state are preserved. Process-exit cleanup
closes admission, cancels and joins native workers and child processes, then
disposes the shared backend. Per-service cleanup does not free another workflow's
backend.

The image build uses a separate patched-GGML DSO. Desktop builds seal and probe
its CLI/resources and test both text/image library load orders. Android statically
links its private C++ runtime, seals stripped DSOs, preserves those bytes through
AGP, and checks final APK/AAB hashes, dependency closure and 16 KiB alignment.
Apple’s final signed-export gate now also checks the image framework payload,
platform/architectures, linkage, distribution signature and embedded image catalog.

Earlier partial verification used source `8a18dff844825440ea63a61691f2a77903cba8f1`.
[Hosted CI 39096103001](https://github.com/alikatgh/quenderin/actions/runs/39096103001)
passed Linux’s real pinned image build/probe, both Node test/build jobs, Kotlin
core, JNI syntax and the existing iOS SDK compile. It exposed a Swift 6 global-page
size concurrency error, experimental website fallback recommendation and a Beam
fixture variable-scope error that were subsequently corrected. It predates the
complete workflows above and is not evidence for the final candidate. Independent
reviews and targeted host fixtures cover source provenance, prompt protocols,
multipart installation, private storage, resource bounds, cancellation and cleanup.

**Final engineering verification passed** at revision
[`1d5f4452b0dd096fdaab737bc4581562f3bce666`](https://github.com/alikatgh/quenderin/commit/1d5f4452b0dd096fdaab737bc4581562f3bce666).
[CI 39106905620](https://github.com/alikatgh/quenderin/actions/runs/39106905620)
completed successfully with **all 18 jobs passing**. The separate
[catalog URL check 39106905664](https://github.com/alikatgh/quenderin/actions/runs/39106905664)
also passed on that exact revision.

- **Apple:** the actual iOS and universal macOS Prism frameworks, linked vision
  bridge, Swift tests and iOS SDK app compilation passed.
- **Android:** the actual Prism JNI app built a debug APK and an **unsigned**
  release AAB. Both packages passed image-library identity, dependency-closure
  and 16 KiB alignment checks; Kotlin core and native runtime/memory-guard tests
  passed.
- **Desktop:** Linux and Windows passed packaged ASAR addon probes and packaged
  image/vision runtime verification. The macOS Electron lab package passed its
  image and vision runtime proofs; it is separate from the native Mac App Store
  product. Independent image-runtime build jobs passed on all three host systems.
- **Windows private storage:** actual protected-DACL approval-store tests and
  positive/negative synthetic ACL policy fixtures passed on the Windows runner.

No local weights, simulator runs or physical-device runs are authorized for this
update. Full-weight inference, image quality, measured memory/speed and native
rendered UI and ARMv7 support remain unverified. The existing hosted Bonsai CPU
generation check does not validate full-weight inference for the new models.
At that engineering revision, no 0.5.0 archive, signing, store submission or public
app availability had been established. The October 19 record above carries the
subsequent native archive and processing results. The dated October 16 store record below is historical; the
October 19 refresh above supersedes its pending-review status.
Windows/Linux desktop packages and their distribution channels remain separate
from the native Apple and Android store releases.

## Verified release memory — 16 October 2026

This is the reusable project release record, recovered from the repository's
July release history and the live store consoles. Refresh dated state before
reusing it; build success, signing, submission and availability are separate.

- Apple app **6789854363**, bundle `ai.quenderin.Quenderin`, signing team
  `9M2B2P4KSA`. Both iOS and macOS **0.4.0 (19)** are **Waiting for Review**.
  Both submissions retain **Automatically release this version** and immediate
  release to all users after approval. **0.3.0 (15)** remains the public version;
  submission is not approval or public availability.
  - [iOS submission](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/58d4e201-3d64-4c88-a76f-d2762d80757d), submitted 16 October at 13:48 Asia/Ulaanbaatar.
  - [macOS submission](https://appstoreconnect.apple.com/apps/6789854363/distribution/reviewsubmissions/details/fb941b2e-296d-407f-b5b1-73c1d19bb308), submitted 16 October.
- Xcode Cloud team `f68608a6-96f8-4330-b123-b99c104eec71`, product
  `4F96019F-D3C2-4ECE-AA57-12D901AC24A3`, existing workflow **Bonsai 2 App Store**.
  Workflow ID: `76741952-1095-40B7-AA3D-9DA19B3682F2`. It is enabled, starts on
  pushes to `codex/bonsai2-27b-20261012`, and automatically cancels superseded
  builds. It has only iOS/macOS Archive actions, with no simulator/device actions.
  Latest successful build is **19**; both signed-export verifiers confirmed
  version 0.4.0, build 19 and the pinned Prism revision. Cloud build ID:
  `6e352c62-20dc-49ea-bb09-a21a47f3eb8d`. Source:
  `2c1bf547846c0565f97477ff0b967b46735deecc`, merged in
  [PR 161](https://github.com/alikatgh/quenderin/pull/161) as
  `d5b5dcb91bff011137ae355ed57a6dab7147303f`. Use a later counter for another
  archive and recheck the live value. At task start the included 25-hour plan
  showed 3h 13m used / 21h 47m available, resetting October 28; subsequent builds
  consumed part of that allowance. No paid upgrade was made.
- [Play Console](https://play.google.com/console/u/0/developers/6289191549337108258/app/4976280765138921912/releases/overview):
  developer `6289191549337108258`, app `4976280765138921912`, package
  **ai.quenderin.app**. Highest observed bundle is **2 (0.2.0)**, active on
  Closed testing → Alpha, track `4700414835984777148`. Candidate 0.4.0 uses code 4.
- Android's established build loads **`android/keystore.properties`** (root of
  the Gradle project). That file and its referenced private upload key are
  machine-local and gitignored. Git history confirms the July signed release;
  it does **not** contain the private key. No repository signing secrets were
  configured when checked on 16 October.
- [Registered upload certificate](https://play.google.com/console/u/0/developers/6289191549337108258/app/4976280765138921912/keymanagement)
  SHA-256: `8B:38:F4:E5:85:88:3A:B7:37:F2:91:8F:49:90:BA:40:17:67:A0:39:37:EB:2A:68:72:88:BD:E3:E9:49:CF:3D`.
  Match this **upload** fingerprint before signing; Play's app-signing certificate
  is different. The matching private key was not found on this Mac after checking
  project/standard signing paths, available session records, keychain metadata
  and a focused connected Drive search. Android 0.4.0 **compiled successfully**
  as an APK and unsigned release AAB in hosted CI; it was **not uploaded to Play**.
  Do not claim that recovering the public fingerprint recovered the private key.
- An earlier App Store Connect banner mentioned an updated Paid Applications
  Schedule, but both 0.4.0 submissions were accepted without a new agreement
  action. No legal terms were accepted in this task. Recheck any future blocker
  rather than assuming the earlier banner prevents submission.

[CI 38856241939](https://github.com/alikatgh/quenderin/actions/runs/38856241939)
passed all 13 jobs on the exact archived source. This includes tiny synthetic
Muse CPU decode and save/reload, bounded Bonsai generation on the hosted runner,
576 Apple runtime tests (9 skips), 574 standard Swift tests (6 skips), Android
packaging, Windows/Linux native-addon and packaged-app checks, and catalog and
source-provenance checks. Catalog URL liveness and independent engineering/UI
review also passed. Do not submit build 18: it predates the Muse graph fix.

The [engineering article](https://quenderin.org/blog-muse-engineering),
[model update](https://quenderin.org/blog-bonsai-small-muse-spark) and
[changelog](https://quenderin.org/changelog) are live. Static Worker publication
`cfa3e413-b0a8-438d-8550-033d76b798e9` preserved the existing Worker code and
settings. The expanded dynamic model-release feed is committed source only;
it was not activated. No Cloudflare deployment secret was configured in GitHub.

The October 16 task explicitly excludes local model downloads, simulators and
physical-device runs. Host fixture checks and hosted compilation are permitted;
full-weight Muse inference and native UI/device behavior remain unverified. Do not
present old screenshot or inference evidence as validation of the 0.4.0 candidate.

| Product | Public channel | Owner guide |
|---|---|---|
| **macOS** (native Swift) | **Mac App Store only** (free) | [MAC_APP_STORE.md](MAC_APP_STORE.md) |
| **iOS** | App Store | § iOS below + [STORE_SUBMISSION.md](STORE_SUBMISSION.md) |
| **Android** | Google Play | § Android below |
| **Windows** | Microsoft Store **+** GitHub `.exe` | [MICROSOFT_STORE.md](MICROSOFT_STORE.md) |
| **Linux** | GitHub AppImage/deb (+ Flathub later) | [WINDOWS_LINUX_STRATEGY.md](WINDOWS_LINUX_STRATEGY.md) |

---

## Android (Google Play)

### 1. Reuse the existing upload keystore
Use the existing private upload key matching the fingerprint above. A new key
cannot sign an update until Google's separate upload-key reset process completes.
Do not generate a replacement as a workaround for a missing local configuration.
Inspect public certificate metadata with `keytool -list -v -keystore /path/to/key`;
enter passwords interactively, never in committed commands or task output.

### 2. Point the build at it — WITHOUT committing secrets
The established build reads the human-managed `android/keystore.properties`
(gitignored, together with `*.jks` and `*.keystore`). Restore the existing secure
signing setup; do not print, copy or create credential contents in an agent
session. A path or existing signing-job name is enough to locate the setup.
`app/build.gradle.kts` loads it and signs the **release** build automatically. With no file present,
release still *builds* (unsigned) — so CI and contributors are never blocked.

### 3. Build the release bundle
Use the pinned, patched Prism runtime, including the compiled Muse ABI. A stock
checkout or mock engine is not this release. First check disk headroom; hosted CI
is preferable when this Mac cannot fit native build output.

```sh
python3 scripts/prepare_prism_runtime.py fetch --destination /absolute/new/prism-source
ANDROID_NDK_HOME="$ANDROID_HOME/ndk/26.3.11579264" \
  bash scripts/build_android_diffusion.sh /absolute/new/android-diffusion
cd android
./gradlew :app:bundleRelease --no-daemon --console=plain \
  -Pquenderin.runtime=prism -Pquenderin.llamaDir=/absolute/new/prism-source \
  -Pquenderin.diffusionLibDir=/absolute/new/android-diffusion/jniLibs
cd ..
python3 scripts/verify_diffusion_android_package.py \
  --libraries /absolute/new/android-diffusion/jniLibs \
  --package android/app/build/outputs/bundle/release/app-release.aab
```

Output: `android/app/build/outputs/bundle/release/app-release.aab`. Without the
existing signing properties this is **unsigned**. Check with `jarsigner -verify`
and `keytool -printcert -jarfile` and match the registered upload fingerprint.
The CI Android job compiles the release bundle and actual native runtime without
credentials; this does not upload a Play release. API 36, AGP 8.10.1 and Gradle 8.11.1
are the 0.4.0 build configuration. Keep the existing 16 KB native linker alignment.
[Current target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878)
require API 36 for updates after 31 August 2026.

### 4. Play Console (your account)
- Open the existing `ai.quenderin.app` record and upload the signed `.aab` to an
  existing Alpha track. For this task, do not launch a device or simulator;
  report that runtime validation has not been performed.
- **Data safety form:** review against the public privacy policy. Network activity includes
  user-selected Hugging Face downloads, optional model search, and public release metadata
  from quenderin.org when model selection is opened. Those catalog/download
  requests carry no chats or files. In versions with the optional Step 5 workflow,
  an approved request sends its prompt and selected conversation to the user's
  configured CUDA host. Review the actual destination and consent behavior
  separately; a local-chat disclosure alone does not describe this workflow.
  Declare the **`dataSync`** foreground-service type used for model downloads.
- **Content rating (IARC):** file **Mature 17+** — an unrestricted local LLM can emit mature text.
- **Privacy policy URL:** `https://quenderin.org/privacy` (already hosted + in-app).
- Promote only after device validation and the console's production-access gates
  pass. The September record of 7 opted-in testers is historical, not current
  proof of production eligibility; check the current Dashboard before promotion.

---

## iOS (App Store)

### 1. Prepare the committed project

```sh
xcodegen generate --spec apple/QuenderinApp/project.yml
python3 scripts/generate_muse_artifacts.py --check
python3 scripts/check_catalog_parity.py
```

Commit both `project.yml` and the generated Xcode project when versions change.
Cloud regenerates and rejects project drift.

Both XcodeGen plist templates must use `$(MARKETING_VERSION)` and
`$(CURRENT_PROJECT_VERSION)`. Changing the build settings alone does not override
a hardcoded plist version: Cloud build 17 exported 0.3.0 despite the 0.4.0 build
setting. The signed-export verifier now requires the version and minimum build
declared by both targets in `project.yml`, while allowing Cloud's higher counter.

### 2. Use the existing Xcode Cloud workflow
Open [Quenderin Xcode Cloud](https://appstoreconnect.apple.com/teams/f68608a6-96f8-4330-b123-b99c104eec71/xcode-cloud/products/4F96019F-D3C2-4ECE-AA57-12D901AC24A3/groups).
Reuse **Bonsai 2 App Store**, explicit `QUENDERIN_RUNTIME=prism`, and its iOS
`Quenderin` / macOS `QuenderinMac` App Store Archive actions. Select the reviewed
pushed commit and record its full SHA. The post-clone hook builds the pinned
framework before package resolution; post-build hooks verify the signed exports,
source patch, compiled capability, catalog, versions and distribution-team signature.
A green build and completed App Store Connect preparation are required before
selecting that exact build in each platform's version. TestFlight distribution
is optional. For each submission select **Automatically release this version**.

### 3. App Store Connect (your account)
- **Privacy policy URL:** `https://quenderin.org/privacy` (paste into App Information).
- **Apple Standard EULA:** opt in (App Information → one click; "Submit for Review" stays grey otherwise).
- **Age rating:** **17+** (mature local-LLM output).
- **App Review notes (Guideline 4.2):** explain the ordinary device-sized models and optional large models, "be on Wi-Fi," and
  that onboarding *is* the first-use experience by design (it's not an empty app).
- **App privacy:** "Data Not Collected."

---

## What stays out of git (and why)

`keystore.properties`, `*.jks`, `*.keystore`, `*.p12` are gitignored. The Android signing key and the
iOS distribution certs are the two things that, if leaked, let someone ship a malicious update under
your identity — they belong in your password manager / Apple's keychain, never the repo. Everything the
build needs to *find* them is an absolute path in the gitignored properties file.

---

## Cross-references
- `docs/SHIP_READINESS.md` — the full "needs you" ledger (questionnaires, accounts, the closed items).
- `docs/DEVICE_VERIFICATION.md` — capture the real tok/s (incl. the CPU-vs-GPU A/B) before listing.
- `android/INTEGRATION.md` — the native build + GPU/Vulkan opt-in.
