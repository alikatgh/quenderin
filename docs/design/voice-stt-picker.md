# Desktop voice setup and local dictation

The welcome wizard opens with the existing local chat model catalog and download
routes. The second step offers optional voice dictation. Starting a voice download
saves the selection and leaves the work in the local server when the wizard closes.
Settings → Voice can change the selection, remove a model, turn dictation off, or
send a transcript automatically. By default the composer keeps the transcript as a
draft. Both chat composers support a held mic button and Ctrl/⌘+Shift+M.

## Catalog and credits

The desktop picker uses the 29 curated ASR models in
`@handy-computer/models@0.2.3`. The package provides the default quantization,
English grades, benchmark wait times, recommendations, search helpers, sizes,
and minimum engine versions. The Handy desktop speed meter counts how many of
2, 3.5, 7.5 and 20 seconds a benchmark wait beats. It uses a 30-second dictation.
An English grade of `—` indicates that the model does not claim English. A `?`
indicates that the model claims English and lacks an English measurement.

`node scripts/sync_handy_speech_catalog.mjs --check --ref /path/to/handy-ref`
compares the package data with Handy's complete upstream catalog at
`05efc5fc180197dc0fa9d568dd9812904b723b8b`. The desktop app reads the installed
package. Android and Apple continue to use the existing Hex model manifest.

The table shows the license for each model. The app distributes Handy's MIT
notice under Settings → Voice → Voice credits and licenses.

## Local server

| Endpoint | Purpose |
| --- | --- |
| `GET /api/speech/models` | Public catalog with English picks, measured grades and runtime compatibility |
| `GET /api/speech/credits` | MIT notice |
| `POST /api/speech/downloads` | Start a background download with `{ modelId }` |
| `GET /api/speech/downloads` or `GET /api/speech/downloads/:modelId` | Restore snapshots after connecting or select a partial after restart |
| `POST /api/speech/downloads/:modelId/{pause,resume,cancel,retry}` | Control a download |
| `DELETE /api/speech/models/:modelId` | Remove a model and its partial |
| `GET /api/speech/settings` or `PUT /api/speech/settings` | Read or update `voiceEnabled`, `modelId` and `autoSend` |
| `POST /api/speech/transcribe` | Transcribe a raw `audio/wav` request with the selected installed model |

Downloads, settings and transcription require dashboard authentication. The
existing authenticated WebSocket sends `speech_download_progress` snapshots.
The server throttles progress and keeps one active download slot. Each transfer
writes to `~/.quenderin/models/speech/<filename>.part` and checks the exact byte
count and catalog SHA-256 before renaming. When a ranged request receives HTTP
416, the server clears the stale partial and tries once from zero. Pause keeps
the partial and cancel clears it. Transient errors use bounded backoff.

Settings are written using an atomic rename. The engine gate compares each
model's `minEngine` against the pinned transcribe.cpp version in
`shared/speech-runtime.json`. A blocked model stays visible with its engine
requirement. The download and transcription routes reject blocked models.

The browser captures audio only after a microphone gesture. Web Audio resamples
the recording and the encoder downmixes to 16 kHz mono PCM16 WAV. The authenticated
loopback route rejects invalid audio and WAV bodies above 64 MiB. The existing
HexSpeechAdapter verifies the on-disk model and runtime, then invokes the pinned
native CLI. The adapter keeps browser captures in a private temporary directory
for the duration of the CLI call and clears it on exit. The response's transcript
enters the current composer through its normal send flow.

## Build and verification

Use the existing desktop package flow. On the target host,
`python scripts/prepare_speech_runtime.py build-desktop --work <scratch-directory>`
fetches the pinned engine source, compiles the CLI and stages it under
`build/speech/<os>-<arch>`. Electron packs that directory under `resources/speech`.
The hosted desktop jobs probe the packaged executable's ABI and revision with
`verify-desktop`. Neither command downloads models.

The no-weight tests cover catalog parity, mocked downloads, authenticated HTTP
and WebSocket flows, WAV validation, microphone capture with browser mocks,
and axe checks. The hosted build and runtime identity probe do not exercise
real microphone hardware or inference with GGUF weights.

## Source map

| Quenderin path | Handy source |
| --- | --- |
| `ui/src/vendor/handy/**` | Corresponding files under `src/**`, recorded in each source header |
| `src/services/speech/grading.ts` | `src/lib/models/catalog.ts` and `src/components/shared/SpeedBars.tsx` |
| `src/services/speech/downloadManager.ts` | `src-tauri/src/managers/model/download.rs` |
| `tests/speech-download-manager.test.ts` | `src-tauri/src/managers/model/download/tests.rs` |
| `ui/src/lib/speech/wav.ts` | `src-tauri/src/audio_toolkit/audio/decode.rs` downmix |

Quenderin's integration lives in `src/routes/speech.ts`, the dashboard speech
services and shared wire types, the wizard and Settings bindings, and the browser
and Electron microphone controls.
