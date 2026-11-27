# Local OpenAI-Compatible API (macOS)

Quenderin for macOS includes an **opt-in, loopback-only** HTTP server that speaks the
OpenAI Chat Completions API. Any script, editor plugin, or SDK that accepts a custom
`base_url` can talk directly to the local model already running inside Quenderin — with
zero cloud traffic, no accounts, and no extra daemon to install.

- **Off by default** — nothing listens until you turn it on in Settings.
- **macOS only** — never compiled or enabled on iOS.
- **Loopback only** — binds strictly to `127.0.0.1` (default port `11435`, chosen so it
  does not clash with Ollama's `11434`).

## Turning it on

1. Open **Quenderin** on your Mac and finish model setup (so at least one model is installed).
2. Open **Settings** (`⌘,`) → **Model** → **Local API (for developers)**.
3. Toggle **Serve an OpenAI-compatible API on this Mac** on.
4. Optionally change the **Port** (`1024`–`65535`, default `11435`) or set an **API key**.
5. Click **Copy URL** to copy the base URL:

```text
http://127.0.0.1:11435/v1
```

Quenderin automatically stops the server when you toggle it off or quit the app.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/models` | Lists installed models Quenderin can load (always includes the active model) |
| `POST` | `/v1/chat/completions` | Chat completion (buffered JSON or `text/event-stream` SSE) |

## `curl` examples

### List installed models

```bash
curl http://127.0.0.1:11435/v1/models
```

If you set an API key in Settings, pass it as a Bearer token:

```bash
curl http://127.0.0.1:11435/v1/models \
  -H "Authorization: Bearer YOUR_KEY"
```

### Non-streaming chat completion

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "system", "content": "Answer in one short sentence."},
      {"role": "user", "content": "Why is loopback 127.0.0.1?"}
    ],
    "max_tokens": 128,
    "temperature": 0.7
  }'
```

Omit `"model"` to use whichever model is active in Quenderin, or specify any model ID
returned by `GET /v1/models`.

### Streaming chat completion (SSE)

```bash
curl -N http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "stream": true,
    "messages": [
      {"role": "user", "content": "Count from 1 to 5."}
    ]
  }'
```

## Python (`openai` SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:11435/v1",
    api_key="quenderin",  # or the API key you set in Settings
)

# List installed models
models = client.models.list()
model_id = models.data[0].id

# Non-streaming
reply = client.chat.completions.create(
    model=model_id,
    messages=[{"role": "user", "content": "Say hello in three words."}],
)
print(reply.choices[0].message.content)

# Streaming
stream = client.chat.completions.create(
    model=model_id,
    stream=True,
    messages=[{"role": "user", "content": "Write a haiku about local AI."}],
)
for chunk in stream:
    delta = chunk.choices[0].delta.content
    if delta:
        print(delta, end="", flush=True)
print()
```

## JavaScript / TypeScript (`openai` SDK)

```js
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://127.0.0.1:11435/v1",
  apiKey: "quenderin", // or the API key you set in Settings
});

const models = await client.models.list();
const model = models.data[0].id;

const reply = await client.chat.completions.create({
  model,
  messages: [{ role: "user", content: "Summarize HTTP 415 in one line." }],
});
console.log(reply.choices[0].message.content);
```

## Structured JSON output (`response_format`)

Quenderin enforces JSON output at the llama.cpp GBNF grammar level for standard GGUF models.
Models that do not support grammar-constrained decoding (**Beam**, **Jais**, and **Muse**) reject
`response_format` JSON/schema requests with `400` (`unsupported_response_format`). If native
grammar-sampler initialization fails for any model, the request also fails with `400`
(`unsupported_response_format`).

Combining a JSON response format with a nonempty `stop` sequence returns `400`
(`unsupported_response_format`) before generation in both buffered and streaming modes.

### Any valid JSON object (`json_object`)

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Return {\"city\": ..., \"country\": ...} for Kyoto."}],
    "response_format": {"type": "json_object"}
  }'
```

### Schema-constrained JSON (`json_schema`)

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Classify: The battery lasts all day."}],
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "sentiment",
        "strict": true,
        "schema": {
          "type": "object",
          "properties": {
            "label": {"type": "string", "enum": ["positive", "neutral", "negative"]},
            "confidence": {"type": "number"}
          },
          "required": ["label", "confidence"],
          "additionalProperties": false
        }
      }
    }
  }'
```

Supported JSON Schema keywords compile directly to a deterministic GBNF grammar
(`object`, `properties`, `required`, `string`, string `enum`, `number`, `integer`,
`boolean`, `null`, `array`, `items`). Strict schemas support boolean
`additionalProperties`, including a closed object with no declared properties.
Invalid schemas return `400` (`invalid_response_schema`). Set `json_schema.strict`
to `true` to receive `400` (`unsupported_response_format`) for unsupported constraints
such as `anyOf`, `$ref`, or schema-valued `additionalProperties`. With `strict` omitted
or set to `false`, unsupported schemas can fall back to the generic JSON object grammar.

## Reasoning (`think` extension)

Reasoning models (such as Qwen3 or DeepSeek-R1) default to thinking **off** for fast,
direct answers. Pass `"think": true` to let the model reason and receive the reasoning
chain separately in `reasoning_content` (and `delta.reasoning_content` when streaming):

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "think": true,
    "messages": [{"role": "user", "content": "What is 17 * 23?"}]
  }'
```

## Limits and supported parameters

- **macOS only, loopback only:** Only apps running on the same Mac can connect.
- **One request at a time:** The API shares the app's exclusive on-device engine lease
  with the Quenderin Chat window. If another chat turn or API call is in flight, a new
  request waits up to 30 seconds and then returns `503` (`server_busy`).
- **Connection limits:** The listener closes excess connections when all 16 slots are in use.
  Clients have five seconds to send HTTP headers. The server checks those headers before waiting
  up to 30 seconds for a body.
- **Disconnect cancels generation:** Transport aborts/resets and socket errors cancel
  in-flight generation immediately, while valid TCP write-half-closed clients
  (`shutdown(SHUT_WR)`) still receive their full reply. For streaming (`"stream": true`)
  requests, once HTTP headers and the initial SSE frame are queued (at the first token), a
  peer FIN triggers an ordered SSE comment probe (`:\n\n`) and stalled writes time out so a
  closed peer cancels generation promptly. Because TCP cannot distinguish a clean peer FIN
  from a valid write-half-close before writing, a clean FIN that arrives before the first
  token (during prefill) or on a buffered (`"stream": false`) request becomes observable—and
  cancels or releases the turn—on a transport error/reset or the first response write.
- **Clamped sampling parameters:** `max_tokens` / `max_completion_tokens` defaults to
  `512` (clamped `1`–`4096`), `temperature` is clamped `0`–`2`, `top_p` is clamped
  `0`–`1`. `stop` accepts a string or an array of up to four distinct nonempty strings,
  each at most 256 UTF-8 bytes. Empty strings and duplicates are discarded. Exceeding either
  limit returns `400`. Stop sequences match the exact UTF-8 text.
- **Completion limits and failures:** Reaching the requested token cap or filling the model's
  context during generation produces `finish_reason: "length"`. A native decode failure after
  partial output returns HTTP 500 (`decode_failed`) for buffered requests. If SSE headers are
  already committed, the server sends a `data:` frame containing an `error` object and closes
  the stream without a finish reason or `[DONE]`.
- **Context sizing:** If a manual context setting exceeds the model's estimated memory budget,
  Quenderin loads a smaller window that fits. A model switch returns `503` when no manual
  window fits. A 256-token context leaves up to 192 tokens for the rendered prompt and
  reserves the remaining 64 for generation.
- **No tools yet:** Requests containing `tools` or `tool_choice` (including explicit `null`)
  are rejected with `400` (`tools are not supported yet`) rather than silently ignored.
- **No images yet:** Content arrays with `{"type": "text", "text": "..."}` parts are
  supported; image parts are rejected with `400` (`images are not supported by this
  endpoint yet`).
- **Installed models only (no automatic downloads or deletions):** The API only uses models
  already loaded in Quenderin or already installed on disk. Discovery includes registered sideloads
  and multipart models whose shards are present together at their expected sizes. Listed files
  are verified when selected, including on the first request after launch. When switching to another installed
  model, Quenderin verifies its SHA-256 digest whenever one is pinned (catalog/manifest models
  and sideloaded models with a known digest) and always checks the GGUF header; community
  models without a pinned digest are checked by GGUF header only, and a model already loaded in
  the engine is reused directly. Passing an uninstalled or integrity-failed `model` returns
  `404` (`model_not_found`) without deleting files or starting a download. If no model is
  installed at all, requests return `503`.
- **Model-switch cancellation:** If the request ends before its model switch commits, Quenderin
  keeps the app's selection. While still holding the inference lease it restores the previous
  loaded model if its installed files can still be verified and loaded.
- **No chunked request bodies:** Send a standard `Content-Length` header (max headers
  `16 KiB`, max body `4 MiB`).
- **Privacy:** Prompts and replies are never logged. Only an in-memory count of requests
  served this session is kept for the Settings status view.

## Security model

- **Loopback socket binding:** `NWParameters.tcp` is configured with
  `acceptLocalOnly = true` and `requiredLocalEndpoint = 127.0.0.1:<port>`.
- **DNS-rebinding protection (`Host` check):** Every request must carry a `Host` header
  matching `127.0.0.1:<port>` or `localhost:<port>`. Any other or missing `Host`
  returns `403`.
- **Browser isolation (`Origin` check & no CORS):** Any request carrying an `Origin`
  header is rejected with `403`, and the server never emits `Access-Control-Allow-*`
  headers. Random web pages in your browser cannot probe or drive the local API.
- **Strict `Content-Type` on `POST`:** Send one `Content-Type` header with the case-insensitive
  media type `application/json` and any valid parameters. A missing or malformed value returns
  `415`. Repeating the header returns `400`.
- **Optional Bearer authentication:** When you leave the API key blank, any or no
  `Authorization` header is accepted (matching Ollama's dummy-key convention). When you
  set a key, every request must send `Authorization: Bearer <key>` (checked in constant
  time), else `401`.
