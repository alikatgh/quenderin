# Voice STT picker — architecture (Stage 1 scaffold)

Status: **scaffold only**. Stage 2 implements the bodies below; every placeholder throws
`Error('TODO(stage2): …')` so it is greppable and cannot ship by accident.

Feature: onboarding gains an optional second step, "Talk to your local model by voice".
It downloads one of Handy's 29 curated ASR GGUF models and adds push-to-talk dictation to
the chat composer. Transcription is fully local through the existing
`HexSpeechAdapter`/transcribe.cpp runtime. There are no cloud calls in this feature.

Reference (read-only, not part of this repo): `/workspace/handy-ref`
- Handy at commit `05efc5fc180197dc0fa9d568dd9812904b723b8b` (MIT, © CJ Pais).
- `@handy-computer/models@0.2.3` (MIT) for catalog facts and grading/recommendation method.

---

## 1. Decisions at a glance

| Decision | Value |
| --- | --- |
| Catalog source | Generated snapshot `shared/handy-speech-catalog.json` from Handy's real catalog |
| Model set | Exactly `role == "asr" && curated == true` — **29** models |
| Default file | The catalog's own default quant, `files[model.quant]` (all 29 are Q8_0 today) |
| Download URL | `https://huggingface.co/{repository}/resolve/{revision}/{filename}` |
| Recommended card | `parakeet-unified-en-0.6b` — 697 MB (731,357,568 B) |
| More accurate card | `Qwen3-ASR-1.7B` — 2.0 GB (2,185,030,624 B) |
| Speed meter | Handy UI cutoffs `[2, 3.5, 7.5, 20]` seconds → 0–4 bars |
| Accuracy grades | Handy UI ceilings `A:5 B:10 C:20 D:30`, F above; `?` unmeasured, `—` unsupported |
| Runtime gate | `model.minEngine <= shared/speech-runtime.json.engineVersion` (0.4.1 today) |
| Settings | `~/.quenderin/speech-settings.json`, atomic 0600 write, voice off by default |
| Transport | REST for commands/reads + one WS event for download progress |
| Privacy | Mic → local WAV → local backend → local transcribe.cpp → local LLM |

### Why the snapshot is generated, never typed by hand

`scripts/sync_handy_speech_catalog.mjs` reads Handy's `src-tauri/src/catalog/catalog.json`
(and asserts the `pkg/package/catalog.json` copy is identical), `pkg/package/package.json`,
`COMMIT` and `LICENSE`. It copies ids, names, descriptions, repositories, revisions,
licenses, families, parameters, languages, capabilities, quant, `minEngine`, sizes, hashes,
results, methodology and benchmarks verbatim. The only composed value is the download URL,
built with Handy's documented rule. Duplicate ids, missing files, missing results, a wrong
package version or a catalog/copy mismatch abort generation.

`--check` regenerates in memory and compares byte-for-byte with the committed snapshot;
CI/tests use it to prove parity. No network, no weights.

---

## 2. Module map

### Shared data and types

| Path | Role |
| --- | --- |
| `shared/handy-speech-catalog.json` | Generated 29-model snapshot + results/methodology/benchmarks/provenance |
| `shared/handy-speech-types.d.ts` | **One** declaration of the catalog file shape, imported type-only by backend and UI |
| `scripts/sync_handy_speech_catalog.mjs` | Generator + `--check` + exported `buildSnapshot`/`serialize` |
| `scripts/tests/handy-speech-catalog.test.mjs` | `node --test` invariants and reference parity |

`shared/speech-model-catalog.json` (the 20 Hex models used by desktop, Android and Apple)
and `shared/speech-runtime.json` are **not modified** and keep their schema/ids. The Handy
catalog is a separate, additive picker catalog.

### Backend — `src/services/speech/`

| Path | Responsibility |
| --- | --- |
| `types.ts` | Re-exports catalog types; defines API/download/settings/transcription unions. No `any` |
| `catalog.ts` | Path resolution, load + validation, model lookup, URL/installed-path helpers |
| `grading.ts` | Ported Handy grade/speed/engine formulas; builds `SpeechModelSummary` rows |
| `downloadManager.ts` | Queue, Range/resume, `.part`, SHA-256, atomic rename, retries, error classification |
| `speechSettings.ts` | Persisted choice (`voiceEnabled`, `modelId`, `autoSend`), atomic file I/O |
| `transcribe.ts` | WAV contract, engine gate, `HexSpeechAdapter.transcribe`, response mapping |
| `src/routes/speech.ts` | Mounts the REST surface and bridges progress snapshots to WS |

Existing pieces reused unchanged: `src/services/hexSpeechAdapter.ts` (size + SHA-256
verification, 16 kHz WAV validation, transcribe.cpp/Hex runtime), `src/services/voice.service.ts`,
`src/security/authToken.ts`, `src/websocket/index.ts`, and the LLM download progress pattern.

### UI — `ui/src/`

| Path | Responsibility |
| --- | --- |
| `lib/speech/types.ts` | UI DTOs; catalog entry types re-exported from `shared/` |
| `lib/speech/api.ts` | Typed `/api/speech/*` client over `apiFetch`, `SpeechApiError` |
| `lib/speech/useSpeechDownload.ts` | One model's snapshot + start/pause/resume/cancel/retry; WS reducer |
| `lib/speech/wav.ts` | Float32 → 16 kHz mono 16-bit PCM WAV encoder + size guard |
| `lib/speech/useMicrophone.ts` | Permission state machine and `usePushToTalk` (hold + shortcut) |
| `components/onboarding/VoiceModelStep.tsx` | Onboarding step 2, Recommended/More accurate, skip |
| `components/onboarding/SpeechModelTable.tsx` | Searchable 29-row table, Live preview/Translates filters |
| `components/onboarding/GradeChip.tsx` | Handy-style A–F chip |
| `components/onboarding/SpeedBars.tsx` | Handy's four-bar speed meter + `SPEED_CUTOFFS` |
| `components/VoiceInputButton.tsx` | Composer mic button, permission copy, busy/error states |

`ui/src/App.tsx`'s `WelcomeWizard` remains the owner of onboarding. Stage 2 inserts
`VoiceModelStep` as the optional step after the existing chat-model step; the existing
step 1 behaviour is unchanged. The Settings screen reuses the same components later.

---

## 3. Data flow

### 3.1 Download

```
VoiceModelStep
  │ user selects model, presses "Download 697 MB"
  ▼
POST /api/speech/downloads { modelId }
  │  route validates id, engine compatibility (minEngine <= 0.4.1)
  ▼
SpeechDownloadManager.start
  │  phase queued                     (one active download; others wait)
  ▼
GET https://huggingface.co/{repository}/resolve/{revision}/{filename}
  │  Range: bytes=<.part size>-       (resume; 206 expected, 416 => restart at 0)
  │  stream chunks → <filename>.part   phase downloading
  ▼
size check + SHA-256 over the .part   phase verifying
  │  exact catalog size AND catalog sha256
  ▼
rename .part → <filename>             phase installed
  │
  └─ WS speech_download_progress {snapshot} at each transition/throttled tick
```

The final filename never exists until the bytes are complete and verified, so a chat can
never load a torn GGUF. A failed verification deletes the `.part`; a paused download keeps
it; a cancelled one deletes it. The download is background work: onboarding can advance
while it runs, exactly like the existing chat-model download.

### 3.2 Transcription and chat

```
Composer mic button (gesture only)
  │ getUserMedia → MediaStream
  ▼
MediaRecorder / WebAudio capture
  │ mix to mono, resample to 16 kHz, encode 16-bit PCM WAV
  ▼
POST /api/speech/transcribe   Content-Type: audio/wav   (<= 64 MiB)
  │ route re-validates RIFF/WAVE, 16 kHz, mono, 16-bit, size
  │ resolves modelId, rejects minEngine > runtime
  ▼
HexSpeechAdapter.transcribe({ model, wav, format, language })
  │ existing local runtime: quenderin-speech-cli / transcribe.cpp
  ▼
SpeechTranscriptionResult { text, rawText, language, backend, durationMs, segments }
  │
  ▼
{ text, rawText, ..., autoSend }
  │
  ├─ insert transcript into the composer
  └─ if settings.autoSend: send as a normal chat message to the chosen local LLM
```

The chosen LLM is whatever step 1 selected; the voice feature does not change model
selection or chat routing. The transcript is never written to logs by this feature.

---

## 4. REST and WebSocket contract

All routes are loopback-only like the rest of the dashboard. Mutating methods
(`POST`, `PUT`) require the existing per-launch `X-Auth-Token`. `GET /api/speech/models` is
public like the model catalog; `GET /api/speech/settings` returns user data and must be
token-gated (add `/api/speech/settings` to `PROTECTED_READ_PREFIXES` or gate it inside the
router). Errors use `{ error: string, code: string }`.

| Method + path | Body / query | Success | Notes |
| --- | --- | --- | --- |
| `GET /api/speech/models` | — | `SpeechModelListResponse` | runtime version, recommended/accurate ids, methodology, 29 rows |
| `POST /api/speech/downloads` | `{ modelId }` | `202` + snapshot | `409 unsupported-engine`, `404 unknown-model`, `409 already-installed` |
| `GET /api/speech/downloads/:modelId` | — | snapshot | `404` if never started |
| `POST /api/speech/downloads/:modelId/pause` | — | snapshot | keeps `.part` |
| `POST /api/speech/downloads/:modelId/resume` | — | snapshot | `Range` resume |
| `POST /api/speech/downloads/:modelId/cancel` | — | snapshot | deletes `.part`, phase idle |
| `POST /api/speech/downloads/:modelId/retry` | — | snapshot | backoff policy |
| `POST /api/speech/transcribe` | raw WAV | `SpeechTranscriptionResponse` | `415` non-WAV, `413` > 64 MiB, `409` unsupported engine, `503` runtime unavailable |
| `GET /api/speech/settings` | — | `SpeechSettingsResponse` | token-gated |
| `PUT /api/speech/settings` | `UpdateSpeechSettingsRequest` | `SpeechSettingsResponse` | unknown `modelId` → `400` |

`SpeechModelListResponse`:

```jsonc
{
  "runtimeEngineVersion": "0.4.1",
  "recommendedModelId": "parakeet-unified-en-0.6b",
  "accurateModelId": "Qwen3-ASR-1.7B",
  "methodology": { "dictationSeconds": 30, "maxLanguageErrorPercent": 20, "...": "from snapshot" },
  "models": [
    {
      "model": { "id": "…", "name": "…", "description": "…", "file": { "size": 731357568, "…": "…" }, "…": "…" },
      "englishGrade": { "letter": "A", "label": "A−" },
      "waitSeconds": 1.1867,
      "speedLevel": 4,
      "engine": { "pinnedVersion": "0.4.1", "requiredVersion": "0.2.4", "compatibility": "supported" },
      "installed": false,
      "installedBytes": null
    }
  ]
}
```

### WS event

The existing `useAgentSocket` message union gains one frame:

```ts
{ type: 'speech_download_progress', snapshot: SpeechDownloadSnapshot }
```

```ts
type SpeechDownloadSnapshot = {
  modelId: string;
  phase: 'idle' | 'queued' | 'downloading' | 'paused' | 'verifying' | 'installed' | 'error';
  downloadedBytes: number;
  totalBytes: number;
  percent: number;              // 0–100; 0 when total unknown
  bytesPerSecond: number | null;
  etaSeconds: number | null;
  error: { kind: SpeechDownloadErrorKind; message: string; status: number | null } | null;
  updatedAt: string;            // ISO-8601
};
```

Progress ticks are throttled (about 4/s) and always emitted on phase changes, so a slow
network cannot flood the WS. `GET /api/speech/downloads/:modelId` is the reconnect fallback.

---

## 5. Download state machine

```
                    start()                    first byte
        idle ─────────────────▶ queued ─────────────────────▶ downloading
         ▲                        │                              │   ▲
         │ cancel()               │ cancel()                     │   │ resume() (Range)
         │                        ▼                              ▼   │
         └────────────────────── idle ◀────── cancel() ──────── paused
                                                                  │
                                          all bytes written        │
                                                                  ▼
                                                             verifying
                                                              │      │
                                             size+sha256 ok    │      │ mismatch / write failure
                                                              ▼      ▼
                                                          installed  error
```

Transitions:
- `idle → queued` on `start`; a second request while another model downloads stays `queued`.
- `queued → downloading` when the single download slot is free.
- `downloading → paused` on `pause` (abort request, keep `.part` and bytes).
- `paused → queued/downloading` on `resume` with `Range: bytes=<.part size>-`.
- `downloading → verifying` when the expected byte count is reached.
- `verifying → installed` after exact size + SHA-256 match; then atomic rename.
- Any failure → `error`, never `installed`. `retry` → `queued` after backoff.
- `cancel` from any live phase → abort, delete `.part`, `idle`.
- App restart: a `.part` is resumable; a final file without a verified install record is
  re-verified before being trusted.

### Error kinds (exhaustive)

| Kind | Trigger | User-facing recovery |
| --- | --- | --- |
| `network` | fetch/DNS/socket failure, timeout, 5xx after retries | "Check your connection" + Retry |
| `disk-full` | `ENOSPC` on write/rename | free space, Retry; no final file |
| `checksum-mismatch` | size or SHA-256 differs | `.part` deleted, "Download again" |
| `http-404` | artifact missing at the pinned revision | no retry loop; report catalog drift |
| `http-416` | stale `.part` outside the remote object | restart from zero automatically |
| `unsupported-engine` | `minEngine > pinned runtime` | listed but not downloadable |
| `permission` | `EACCES`/`EPERM` on the models directory | show directory + fix |
| `cancelled` | user cancel | informational, no alert |
| `unknown` | anything unclassified | message + Retry, never a raw stack |

Retry policy: exponential backoff with jitter, bounded attempts (default 5), base 500 ms,
cap 30 s; never retry `unsupported-engine`, `http-404`, `checksum-mismatch` or `disk-full`
automatically (those need a user action).

---

## 6. Grading and speed (ported, not invented)

Handy's UI values, which this feature mirrors:

```ts
const GRADE_CEILINGS = { A: 5, B: 10, C: 20, D: 30 }; // error %; F at/above 30
const SPEED_CUTOFFS = [2, 3.5, 7.5, 20];              // seconds; 4/3/2/1/0 bars
const BENCHMARK_DICTATION_SECONDS = 30;
```

- English accuracy: `results[id].accuracy.en.error` → letter. Handy's package also emits
  `+`/`−` modifiers at `cbrt(2)` sub-grade steps; the chip label carries them (e.g. Parakeet
  A− at 3.99 %, Qwen3-ASR 1.7B A at 3.23 %). `?` means Handy has no measurement; `—` means
  the model does not claim English.
- Speed: `waitSeconds = 30 / results[id].performance.accelerated` (benchmark Vulkan rig);
  bars = number of `SPEED_CUTOFFS` the wait is under. Parakeet ≈ 1.19 s → 4 bars;
  Qwen3-ASR 1.7B ≈ 7.34 s → 3 bars. A model with no accelerated measurement shows 0 bars
  and `SIZE` still works.
- The UI never recomputes grades: the API sends `englishGrade`, `waitSeconds` and
  `speedLevel`, so there is one source of truth. `SPEED_CUTOFFS` is exported in the UI only
  for the legend/tooltips.
- Size strings are formatted from bytes like Handy: MiB → `"697 MB"`, GiB → `"2.0 GB"`.
  The count in "Show all N models" is `catalog.models.length`, never a literal.

The snapshot also carries `methodology` and `benchmarks` (dataset/split, benchmark machines),
so the picker can explain what a grade means without a network call.

---

## 7. Settings persistence

File: `~/.quenderin/speech-settings.json` (overridable for tests; never committed).

```json
{
  "voiceEnabled": true,
  "modelId": "parakeet-unified-en-0.6b",
  "autoSend": false,
  "updatedAt": "2026-11-27T00:00:00.000Z"
}
```

Rules:
- Defaults: `voiceEnabled: false`, `modelId: null`, `autoSend: false`. "Skip — I'll type"
  writes `voiceEnabled: false` and leaves any downloaded model on disk.
- Writes are atomic: temp file in the same directory + `rename`, mode `0600`; a crash never
  leaves half a file.
- Missing, unreadable or corrupt JSON → defaults, no startup failure.
- `modelId` must exist in the snapshot; unknown ids are rejected by `PUT`.
- Settings are user data: the GET is token-gated. The file contains no secrets, only the
  choice, so it is safe to inspect and delete.

The picker's local UI state (search text, filters, expanded) is ephemeral and not persisted.

---

## 8. Privacy, security and failure surfaces

- Microphone access is requested only from a user gesture. Denied/no-device/unsupported
  states show how to fix it; the composer stays usable by typing.
- Recorded audio is sent only to `127.0.0.1` over the authenticated local server, held in
  memory for the request, and never logged. The response is the transcript only.
- WAV is validated server-side: size ≤ 64 MiB (`shared/speech-runtime.json` bound), RIFF/WAVE,
  PCM, mono, 16 kHz, 16-bit, non-empty.
- Download URLs are the pinned Hugging Face hosts from the snapshot; no user-supplied URL,
  no redirect-to-`file:` handling, no shell. Filenames come from the snapshot, not the request.
- SHA-256 is the trust anchor; a hash mismatch is a hard failure even if TLS succeeded.
- Transcripts are inserted as text, never as HTML/markdown that could execute.
- Tokens/secrets never enter the snapshot, settings file, logs, tests or docs.

---

## 9. Test plan

Root (`npx vitest run`, baseline 906 passing):

| File | Stage 1 state | Stage 2 target |
| --- | --- | --- |
| `tests/handy-speech-catalog.test.ts` | **real** | keep + extend |
| `tests/speech-grading.test.ts` | todo | exact Handy grade/speed table |
| `tests/speech-download-manager.test.ts` | todo | mocked fetch/fs: progress, resume Range, 416, checksum, cancel, backoff, ENOSPC |
| `tests/speech-routes.test.ts` | todo | in-process Express, auth, status codes, settings round-trip |
| `tests/speech-settings.test.ts` | todo | temp dir, atomic write, corrupt file, reset |
| `tests/speech-transcription.test.ts` | todo | synthetic WAV fixtures, 413/415/409, fake adapter |
| `scripts/tests/handy-speech-catalog.test.mjs` | **real** | `node --test`, `--check` parity |

The catalog test is real now and asserts:
- exactly 29 curated ASR entries, unique ids, `role/curated`, quant/hash/size shape;
- Parakeet Unified English 0.6B = 731,357,568 bytes, exact Q8_0 filename and hash;
- Qwen3-ASR 1.7B present at 2,185,030,624 bytes (≈2.0 GiB);
- results/methodology/benchmarks for every model;
- provenance (Handy repo/commit/MIT copyright, package 0.2.3);
- every URL equals the pinned `resolve/{revision}/{filename}` rule;
- `--check` byte parity when `/workspace/handy-ref` is available.

UI (`cd ui && npx vitest run`, baseline 30 passing):

| File | Stage 1 state | Stage 2 target |
| --- | --- | --- |
| `ui/tests/voice-model-step.test.tsx` | todo | cards, "Show all 29", search, both filters, columns, download/error/skip |
| `ui/tests/voice-input.test.tsx` | todo | mocked getUserMedia/MediaRecorder, permission states, PTT, WAV, transcribe, auto-send |
| `ui/tests/a11y-voice.test.tsx` | todo | axe over the step + composer control |

No test downloads weights or touches the network; all external I/O is injected/mocked.
Type gates: `npx tsc --noEmit` at root and `cd ui && npx tsc --noEmit`.

Manual verification deferred by the project brief: real microphone capture and real
transcribe.cpp inference on hardware (no simulator/device runs, no weight downloads in this
update). Source-level integration is not the same as tested inference; reports must say so.

---

## 10. Open questions for Stage 2 / product

1. **Recommended/accurate source of truth.** Handy's package `recommend(["en"])` yields
   Parakeet (`best`+`fast`) and Qwen3-ASR 1.7B (`accurate`). We can either port that
   recommendation for English or pin the two ids from the payload. Prefer porting the real
   method, with a snapshot test that pins today's answer.
2. **Overall grade for non-English models.** The spec's table shows one **EN** column. For a
   model with no English measurement, show `?`; do we also need an "All languages" aggregate
   like Handy's Models page? Deferred until after the picker ships.
3. **Engine gate copy.** All 29 models today require ≤ 0.4.0 and the pinned runtime is 0.4.1,
   so the "Needs newer speech engine" path is unexercised by real data. Stage 2 should test it
   with a fixture, and we must re-check when the snapshot is regenerated.
4. **Where the installed model lives.** Proposal: `~/.quenderin/models/speech/<filename>`.
   `HexSpeechAdapter` currently expects its own `shared/speech-model-catalog.json` ids and
   directory layout; Stage 2 must bridge the Handy id to an adapter manifest entry without
   mutating the 20-model Hex catalog (which Android/Apple also read).
5. **Mic device selection.** Use the OS default for v1; is a device picker needed in Settings?
6. **Auto-send default.** `false` (insert only). Should the onboarding step explain the
   difference, or is Settings enough?
7. **Windows/Linux permission copy.** `getUserMedia` denial UX differs from macOS Electron
   `systemPreferences.getMediaAccessStatus`; Stage 2 should centralize the copy.
8. **Deleting models.** The spec covers download/cancel; Settings should later allow removal.
   The manager already exposes `verifyInstalled`, but no delete method is scaffolded yet.
9. **Rate limiting.** The global 600 req/min limit is fine for polling; the transcribe route
   is CPU-heavy and may need its own tighter limit to avoid queueing many decodes.
10. **Snapshot refresh cadence.** Regeneration is manual/pinned. Decide whether a scheduled
    check compares `COMMIT`/package version and opens a PR, without auto-downloading.

---

## 11. Attribution

Handy (MIT, Copyright (c) 2025 CJ Pais) supplied the catalog, grading bands, speed meter and
download-state UX. `@handy-computer/models@0.2.3` (MIT) supplied the catalog package and the
recommendation method. Per-model weight licenses are shown from each entry's `license` field
(e.g. `cc-by-4.0` for Parakeet). The exact notices live in `native/speech/NOTICE.md`, the
repo's existing third-party notice file for the speech runtime.
