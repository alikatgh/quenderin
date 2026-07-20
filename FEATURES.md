# Feature Guide

Comprehensive reference for every major capability in Quenderin.

---

## 1. Multi-model catalog with RAM-aware auto-selection

Quenderin ships with a built-in multi-model catalog spanning coding, reasoning, multilingual, and general-purpose tiers. At startup, it scans which models are present on disk and automatically picks the largest one that safely fits within available system RAM.

**Available models:**

<!-- BEGIN GENERATED: model-catalog (scripts/generate_features_models.py) -->
_13 models — generated from `shared/model-catalog.json`; edit `src/constants.ts` and run `npm run gen:features`, never this table._

| ID | Label | Params | RAM footprint | Download | Quantization |
|----|-------|--------|---------------|----------|--------------|
| `qwen36-35b-a3b` | Qwen3.6 35B MoE (Best Agent, Big Download) | 35B | ~5.5 GB | 13.2 GB download | `UD-IQ3_XXS` |
| `qwen3-14b` | Qwen3 14B (Best Quality) | 14B | ~11 GB | 9.0 GB download | `Q4_K_M` |
| `gemma4-12b` | Gemma 4 12B (Multilingual) | 12B | ~9 GB | 7.1 GB download | `Q4_K_M` |
| `qwen25-coder-7b` | Qwen2.5 Coder 7B (Coding) | 7B | ~6.5 GB | 4.7 GB download | `Q4_K_M` |
| `deepseek-r1-7b` | DeepSeek-R1 7B (Reasoning) | 7B | ~6.5 GB | 4.7 GB download | `Q4_K_M` |
| `llama3-8b` | Llama 3 8B (Best Quality) | 8B | ~6.75 GB | 4.7 GB download | `Q4_K_M` |
| `mistral-7b` | Mistral 7B (All-Rounder) | 7B | ~6 GB | 4.1 GB download | `Q4_K_M` |
| `gemma3-4b` | Gemma 3 4B (Multilingual) | 4B | ~3.8 GB | 2.5 GB download | `Q4_K_M` |
| `qwen3-4b` | Qwen3 4B (Everyday) | 4B | ~3.6 GB | 2.4 GB download | `Q4_K_M` |
| `phi4-mini` | Phi-4 Mini 3.8B (Efficient) | 3.8B | ~3.4 GB | 2.3 GB download | `Q4_K_M` |
| `llama32-3b` | Llama 3.2 3B (Balanced) | 3B | ~3 GB | 2.0 GB download | `Q4_K_M` |
| `llama32-1b` | Llama 3.2 1B (Light) | 1B | ~1.5 GB | 0.8 GB download | `Q4_K_M` |
| `llama32-1b-q2` | Llama 3.2 1B Ultra-Light (Low RAM) | 1B | ~0.7 GB | 0.4 GB download | `Q2_K` |
<!-- END GENERATED: model-catalog -->

**Selection logic:**
1. Iterate catalog from largest to smallest model
2. Check if the model file exists in `~/.quenderin/models/`
3. If memory safety is enabled, verify free RAM against the model's footprint
4. Use the first model that passes both checks

If you want to force a specific model, use the **Use** button in Settings → AI Model Manager (or `POST /api/models/switch` with the model ID).

---

## 2. Generation telemetry (tok/s, TTFT, token count)

Every assistant response in General Chat includes a metadata bar so you can benchmark your hardware and tune settings:

```
⚡ 42 tok/s   •   317 tokens   •   TTFT 0.8s   •   7.5s total
```

| Metric | Technical name | Description |
|--------|----------------|-------------|
| `tok/s` | `tokensPerSecond` | Generation throughput. Useful for comparing models and context sizes |
| `tokens` | `tokenCount` | Output token count for this specific response |
| `TTFT` | `timeToFirstTokenMs` | Milliseconds until the first token was emitted. Reflects model load + prompt evaluation |
| `total` | `durationMs` | Full wall-clock time for the complete response |

**How it works:** `LlmService.generalChat()` records a high-resolution timestamp before generation begins, captures the time of the first emitted token (TTFT), and measures total duration. The `GenerationMeta` object is attached to the WebSocket `chat_response` message and passed to the UI.

**What to watch for:**
- High TTFT on first request = model is loading from disk (normal, happens once)
- High TTFT on later requests = context is large, prompt evaluation is slow — reduce context size
- Low tok/s = model is too large for your hardware — try a smaller tier

---

## 3. Persona presets

General Chat includes five built-in persona presets. Each preset configures its own system prompt, temperature, and max token limit. Switching presets resets the active chat session so there is no persona bleed-through.

| Preset ID | Label | Temp | Max tokens | Description |
|-----------|-------|------|------------|-------------|
| `general` | General Assistant | 0.7 | 2048 | All-purpose helpful assistant, responds in Markdown |
| `code-review` | Code Review | 0.3 | 2048 | Senior engineer persona — flags bugs, security issues, best-practice gaps |
| `creative-writer` | Creative Writer | 0.9 | 2048 | Imaginative writer for stories, emails, blog posts |
| `tutor` | Tutor | 0.5 | 2048 | Patient teacher with analogies and step-by-step examples; uses LaTeX for math |
| `summarizer` | Summarizer | 0.3 | 1024 | Concise bullet-point summarizer for long content |

**Temperature guide:**
- `0.3` — deterministic, factual, consistent (good for code and summaries)
- `0.5–0.7` — balanced creativity and accuracy
- `0.9` — highly creative and varied (good for creative writing)

**How to switch:** Click any preset pill below the chat input. The WebSocket sends a `preset_switch` message to the backend, which calls `LlmService.setPreset()`. The current chat session is cleared and the new system prompt applies to the next message.

---

## 4. Intent classification

Before routing each message to the LLM, Quenderin classifies the user's intent. This allows the system to apply different pipelines — for example, engaging the tool loop for math, or skipping tool calls for pure chat.

**Intent categories:**

| Intent | Trigger examples |
|--------|-----------------|
| `math` | `"what is sqrt(144)"`, `"calculate 15% of 380"`, `"2^10"` |
| `code` | `"write a Python script that..."`, `"refactor this function"`, messages containing a code block |
| `action` | `"open Settings"`, `"tap the button on my phone"`, `"navigate to the home screen"` |
| `image` | `"draw a diagram of..."`, `"generate an illustration of..."` |
| `chat` | Everything else |

**Pipeline:**
1. **Regex-first** — fast pattern matching against specialized regex banks for each intent (`MATH_PATTERNS`, `CODE_PATTERNS`, `ACTION_PATTERNS`, `IMAGE_PATTERNS`)
2. **LLM fallback** — if confidence is low and a model is loaded, a lightweight classification prompt is sent
3. **Result cache** — up to 200 results are cached by normalized input key to avoid re-classifying identical phrases

The intent (`intent`, `confidence`, `source`) is attached to each `chat_response` WebSocket message so the UI can display it.

---

## 5. Tool calling

Quenderin supports a bounded tool-calling loop: the LLM can invoke built-in tools via XML tags, receive the result, and incorporate it into its reply — all within one response.

**Supported tools:**

### `calculator`
Evaluates mathematical expressions using a **recursive descent parser with no `eval`**. Completely safe from code injection.

Supported: `+`, `-`, `*`, `/`, `^`, `%`, `sqrt()`, `sin()`, `cos()`, `tan()`, `log()`, `ln()`, `abs()`, constants `pi` and `e`

Example interaction:
```
User: What is sin(pi/4) * sqrt(2)?

LLM emits:
<tool_call>
<name>calculator</name>
<args>{"expression": "sin(pi/4) * sqrt(2)"}</args>
</tool_call>

Tool result: 1.0000000000000002

LLM response: sin(π/4) × √2 = 1.000
```

### `datetime`
Returns the current date and time in the system timezone. No parameters required.

### `system_info`
Returns OS name, architecture, logical CPU count, total RAM, and free RAM. Useful for the model to reason about hardware constraints.

**Safety limits:**
- Maximum **3 tool calls** per response
- Maximum **3 loop iterations** total
- All parsing is done against explicit XML tags — no shell execution, no `eval`
- Tool execution is synchronous and sandboxed

---

## 6. Download resume

Model files are large (1–8 GB). If a download is interrupted — network dropout, system sleep, or manual stop — Quenderin resumes from the exact byte it stopped at rather than restarting.

**How it works:**
1. A `.download.json` sidecar file is written alongside each partial `.gguf` file, recording the target URL, expected total size, and bytes received so far
2. On re-trigger, the sidecar is read and an HTTP `Range: bytes=<offset>-` request is sent to the server
3. The partial file is appended to rather than overwritten
4. On successful completion, the sidecar is deleted and the model becomes available

---

## 7. Active model lifecycle management

The LLM is a large resource. Quenderin manages it explicitly to avoid holding RAM when the assistant isn't being used.

**Lifecycle states:**
- **Unloaded** — no model in memory; next request triggers load
- **Loading** — single shared `initPromise` prevents race conditions if multiple requests arrive at once
- **Active** — model in memory, idle timer running
- **Unloading** — model context and instance explicitly disposed, RAM returned to OS

**Idle auto-unload:**
After **30 minutes** of no chat activity, the model is automatically unloaded. The timer resets on each message. Active generation blocks unload even if the timer fires.

**Model load deduplication:**
If two requests arrive while the model is loading, both await the same `initPromise` — the model is only loaded once regardless of concurrent callers.

---

## 8. Settings safety and defaults

Quenderin enforces safe boundaries on all configurable values and provides a one-click reset.

| Setting | Allowed values | Default |
|---------|----------------|---------|
| Context size | `512`, `1024`, `2048`, `4096`, `8192` (strict allowlist) | `2048` |
| Memory safety | `true` / `false` | `true` |
| Theme | `light`, `dark`, `system` | `system` |
| Privacy lock | configurable PIN | disabled |

Settings outside the allowlist are rejected by the backend validator before being applied.

**Reset Defaults:** Available in the Settings tab. Restores the defaults locally and pushes them to the backend as a normal `settings_update` message; all values revert without requiring a restart.

---

## 9. Startup resilience and port management

Quenderin handles port conflicts gracefully rather than crashing with an unhandled exception.

**Startup sequence:**
1. Probe `isPortFree(requestedPort)` using a temporary TCP server
2. If busy, scan upward (`+1`, `+2`, …) up to 20 attempts
3. Start Express `http.Server` on the first free port found
4. Initialize `WebSocketManager` **only after** the HTTP server successfully binds (avoiding a double-crash scenario)
5. Print the actual running URL to the terminal

The `WebSocketServer` also registers an explicit `.on('error')` handler, preventing uncaught event emitter crashes.

---

## 10. Privacy-first design

Quenderin is built around the principle that your data never leaves your device.

| Property | Detail |
|----------|--------|
| Zero network calls at inference time | The LLM runs entirely in-process via `node-llama-cpp` |
| No telemetry | No analytics, crash reporting, or usage tracking |
| Local-origin CORS | Express restricts cross-origin requests to local origins |
| Strict docs filename validation | `/api/docs/:filename` uses `path.basename()` and enforces `.md` extension — path traversal blocked |
| WebSocket origin check | Connections from non-local origins are rejected at handshake time |
| Settings input validation | All incoming WebSocket settings are validated against allowlists before use |
| Privacy lock | Optional PIN-based UI lock with configurable idle timeout and lockout behavior |
| Sensitive error suppression | Internal stack traces are not forwarded to the client in production responses |
