# Third-Party Notices — Quenderin Native Speech Runtime (`native/speech`)

Quenderin's local speech integration incorporates concepts, protocol contracts, model
catalog pins, and dictation formatting components from two MIT-licensed open-source
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
