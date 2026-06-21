#!/usr/bin/env python3
"""Translate the rotating hero demo Q&A into every supported language via the DeepSeek API.

Reads  website/i18n/demos/en.json  (the English source of truth)
Writes website/i18n/demos/<lang>.json  for each language below.

DeepSeek is OpenAI-compatible and cheap. Get a key at https://platform.deepseek.com, then:

    DEEPSEEK_API_KEY=sk-... python3 scripts/translate_demos.py
    DEEPSEEK_API_KEY=sk-... python3 scripts/translate_demos.py --force   # overwrite existing

Idempotent: skips languages whose file already exists (unless --force). Retries 3x per
language and validates the q/a array counts before writing. Stdlib only — no pip install.

What it does NOT do: human-quality review. Have a native speaker skim the CJK / Indic /
Arabic output before a major launch — machine translation of marketing copy is good, not perfect.
"""
import json
import os
import sys
import time
import pathlib
import urllib.request
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEMOS = ROOT / "website" / "i18n" / "demos"
EN = DEMOS / "en.json"

# Keep in lockstep with the <option> list in website/index.html (minus English).
LANGS = {
    "zh": "Simplified Chinese",
    "hi": "Hindi",
    "es": "Spanish",
    "fr": "French",
    "ar": "Modern Standard Arabic",
    "bn": "Bengali",
    "pt": "Brazilian-neutral Portuguese",
    "ru": "Russian",
    "id": "Indonesian",
    "ja": "Japanese",
    "ko": "Korean",
}

API_URL = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"

PROMPT = """You are a professional {name} translator localizing a marketing demo for "Quenderin", an offline, on-device AI assistant.

Translate the JSON below from English into {name}. It has two index-aligned arrays: "q" (questions) and "a" (answers); q[i] pairs with a[i].

RULES:
- Natural, idiomatic {name} — not literal. Keep the friendly, concise assistant tone.
- PRESERVE every <strong>...</strong> tag, wrapping the equivalent translated key term.
- Keep "Quenderin" untranslated. Keep technical / proper tokens sensible (taut-line, prusik, Cmaj7, C-E-G-B, Rayleigh, Byzantine, the symbols degC, %, $). Localize units and idioms naturally.
- Keep each answer about the same length — it sits in a small chat bubble.
- Return ONLY valid JSON of the exact shape {{"q": [...], "a": [...]}} with the SAME number of items, in the SAME order. No markdown, no commentary.

JSON:
{payload}"""


def call_deepseek(name, payload):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT.format(name=name, payload=payload)}],
        "temperature": 1.0,
        "response_format": {"type": "json_object"},
        "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Authorization": "Bearer " + os.environ["DEEPSEEK_API_KEY"],
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"]


def load_dotenv():
    """Populate os.environ from a root .env (KEY=value lines) if present. Stdlib, no deps. The .env
    file is gitignored — it never gets committed."""
    f = ROOT / ".env"
    if not f.exists():
        return
    for line in f.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def main():
    load_dotenv()
    if not os.environ.get("DEEPSEEK_API_KEY"):
        sys.exit("Set DEEPSEEK_API_KEY in .env (root) or the environment — get one at https://platform.deepseek.com.")
    force = "--force" in sys.argv
    en = json.loads(EN.read_text(encoding="utf-8"))
    n = len(en["q"])
    src = json.dumps({"q": en["q"], "a": en["a"]}, ensure_ascii=False, indent=2)

    failures = []
    for code, name in LANGS.items():
        out = DEMOS / (code + ".json")
        if out.exists() and not force:
            print("skip %s (exists; pass --force to overwrite)" % code)
            continue
        for attempt in range(3):
            try:
                obj = json.loads(call_deepseek(name, src))
                if not (isinstance(obj.get("q"), list) and isinstance(obj.get("a"), list)):
                    raise ValueError("missing q/a arrays")
                if not (len(obj["q"]) == len(obj["a"]) == n):
                    raise ValueError("count mismatch: q=%d a=%d expected=%d" % (len(obj["q"]), len(obj["a"]), n))
                out.write_text(
                    json.dumps({"q": obj["q"], "a": obj["a"]}, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8",
                )
                print("ok   %s  (%s)" % (code, name))
                break
            except (urllib.error.HTTPError, urllib.error.URLError, ValueError, KeyError, json.JSONDecodeError) as e:
                print("  retry %s (%d/3): %s" % (code, attempt + 1, e))
                time.sleep(2)
        else:
            failures.append(code)
            print("FAIL %s — left unwritten" % code)

    print("\nDone. %d/%d languages written." % (len(LANGS) - len(failures), len(LANGS)))
    if failures:
        print("Re-run to retry: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
