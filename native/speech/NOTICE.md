# Third-Party Notices — Quenderin Native Speech Runtime (`native/speech`)

Quenderin's local speech integration incorporates concepts, protocol contracts, model
catalog pins, and dictation formatting components from four MIT-licensed open-source
projects:

1. **Hex** (`https://github.com/anomalyco/hex`, commit `fd2fafc91b67754065af17b9db70bb1cbbc13bb1`)
   - License: MIT License
   - Copyright (c) Kit Langton / Anomaly
   - Reused components:
     - Embedded loopback IPC & TypeScript host protocol (`@kitlangton/hex`, v2 API)
     - Pinned multi-engine GGUF model catalog & SHA-256 artifacts
     - Dictation formatting, custom vocabulary spelling preservation, spoken list/punctuation normalization, and French spacing (`HEXShared`)

2. **transcribe.cpp** (`https://github.com/anomalyco/transcribe.cpp`, commit `60bed89dab84f7c1fddc3a17ad7fa8a27ddfba19`)
   - License: MIT License
   - Copyright (c) Anomaly
   - Reused components:
     - Unified C inference API (`include/transcribe.h`) across Whisper, Parakeet TDT, Nemotron ASR, Cohere Transcribe, Qwen3-ASR, SenseVoice, GigaAM, Granite Speech, and Silero VAD inside a symbol-isolated shared library.

3. **Handy** (`https://github.com/cjpais/Handy`, commit `05efc5fc180197dc0fa9d568dd9812904b723b8b`)
   - License: MIT License
   - Copyright (c) 2025 CJ Pais
   - Reused components:
     - Desktop onboarding model picker and table, plus the four-bar speed presentation
     - Resumable HTTP downloader from `src-tauri/src/managers/model/download.rs` and audio downmix from `src-tauri/src/audio_toolkit/audio/decode.rs`
     - Accuracy grade bands (`GRADE_CEILINGS` A:5 B:10 C:20 D:30) and speed meter (`SPEED_CUTOFFS` [2, 3.5, 7.5, 20]; four-bar display)

4. **@handy-computer/models** (`https://github.com/handy-computer/models`, v0.2.3)
   - License: MIT License (as declared in the package manifest)
   - Reused components:
     - Pinned catalog, default-quant artifacts and model licenses
     - English recommendations, accuracy grades and benchmark wait times

   The model weights themselves are not redistributed by Quenderin. Each catalog entry
   carries its own license (for example, Parakeet Unified English 0.6B is `cc-by-4.0`);
   the picker shows that license per model, and downloads go directly to the pinned
   Hugging Face revision recorded in the pinned package. The desktop app displays the notices under
   Settings → Voice → Voice credits and licenses.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
