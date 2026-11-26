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

const reply = await client.chat.completions.create({
  messages: [{ role: "user", content: "Summarize HTTP 415 in one line." }],
});
console.log(reply.choices[0].message.content);
```

## Structured JSON output (`response_format`)

Quenderin enforces JSON output at the llama.cpp GBNF grammar level:

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
        "schema": {
          "type": "object",
          "properties": {
            "label": {"type": "string", "enum": ["positive", "neutral", "negative"]},
            "confidence": {"type": "number"}
          },
          "required": ["label", "confidence"]
        }
      }
    }
  }'
```

Supported JSON Schema keywords compile directly to a deterministic GBNF grammar
(`object`, `properties`, `required`, `string`, string `enum`, `number`, `integer`,
`boolean`, `null`, `array`, `items`). Schemas that use unsupported keywords (such as
`anyOf` or `$ref`) automatically fall back to the generic JSON object grammar.

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
- **Disconnect cancels generation:** Closing the client socket mid-stream cancels
  on-device generation immediately.
- **Clamped sampling parameters:** `max_tokens` / `max_completion_tokens` defaults to
  `512` (clamped `1`–`4096`), `temperature` is clamped `0`–`2`, `top_p` is clamped
  `0`–`1`. `stop` accepts a string or an array of strings.
- **No tools yet:** Requests containing `tools` or `tool_choice` are rejected with `400`
  (`tools are not supported yet`) rather than silently ignored.
- **No images yet:** Content arrays with `{"type": "text", "text": "..."}` parts are
  supported; image parts are rejected with `400` (`images are not supported by this
  endpoint yet`).
- **No automatic downloads:** Passing an uninstalled `model` returns `404`
  (`model_not_found`). If no model is installed at all, requests return `503`.
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
- **Strict `Content-Type` on `POST`:** `POST` requests must send
  `Content-Type: application/json` (case-insensitive prefix), else `415`.
- **Optional Bearer authentication:** When you leave the API key blank, any or no
  `Authorization` header is accepted (matching Ollama's dummy-key convention). When you
  set a key, every request must send `Authorization: Bearer <key>` (checked in constant
  time), else `401`.
