#!/usr/bin/env python3
"""Translate the marketing-site UI strings (website/i18n/en.json) into every supported language
via the DeepSeek API. Fills in only the keys MISSING from each language file, so it's cheap and
never clobbers existing (e.g. homepage) translations. Reads the key from .env (gitignored) or env.

    python3 scripts/translate_i18n.py            # fill missing keys in every language
    python3 scripts/translate_i18n.py --force    # re-translate ALL keys (overwrites)

Preserves <strong>/<em>/<a> markup, keeps "Quenderin" + technical tokens, returns a parallel JSON
object with the same keys. Stdlib only — no pip install. Have a native speaker skim the CJK / Indic
/ Arabic output before a major launch; machine translation of marketing copy is good, not perfect.
"""
import json
import os
import sys
import time
import pathlib
import urllib.request
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
I18N = ROOT / "website" / "i18n"
EN = I18N / "en.json"

LANGS = {
    "zh": "Simplified Chinese", "hi": "Hindi", "es": "Spanish", "fr": "French",
    "ar": "Modern Standard Arabic", "bn": "Bengali", "pt": "Brazilian-neutral Portuguese",
    "ru": "Russian", "id": "Indonesian", "ja": "Japanese", "ko": "Korean",
}
API_URL = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"
BATCH = 30  # keys per request

PROMPT = """You are a professional {name} translator localizing the Quenderin marketing website (an offline, on-device AI assistant).

Translate the VALUES of this JSON object into {name}. Keep every KEY exactly as-is.

RULES:
- Natural, idiomatic {name} marketing copy — not literal.
- PRESERVE all HTML tags exactly: <strong>...</strong>, <em>...</em>, <a href="...">...</a>. Translate the text inside them; never change an href value or a tag name.
- Keep "Quenderin" untranslated. Keep technical / proper tokens sensible (GGUF, llama.cpp, Wi-Fi, API, Q4_K_M, GPU, RAM, CPU, Hugging Face, MIT, Apache 2.0, iOS, Android, macOS, Linux, Raspberry Pi, M-series Mac). Localize units and idioms.
- A trailing arrow (→ or ←) stays.
- Return ONLY a JSON object with the SAME keys and translated values. No markdown, no commentary.

JSON:
{payload}"""


def load_dotenv():
    f = ROOT / ".env"
    if not f.exists():
        return
    for line in f.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def call_deepseek(name, payload):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT.format(name=name, payload=payload)}],
        "temperature": 1.0,
        "response_format": {"type": "json_object"},
        "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(API_URL, data=body, headers={
        "Authorization": "Bearer " + os.environ["DEEPSEEK_API_KEY"],
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]


def translate_batch(name, items):
    payload = json.dumps(items, ensure_ascii=False, indent=2)
    for attempt in range(3):
        try:
            obj = json.loads(call_deepseek(name, payload))
            if not isinstance(obj, dict):
                raise ValueError("response is not a JSON object")
            missing = [k for k in items if k not in obj]
            if missing:
                raise ValueError("missing keys in response: " + ", ".join(missing[:3]))
            return {k: obj[k] for k in items}
        except (urllib.error.HTTPError, urllib.error.URLError, ValueError, KeyError, json.JSONDecodeError) as e:
            print("    retry (%d/3): %s" % (attempt + 1, e))
            time.sleep(2)
    return None


def main():
    load_dotenv()
    if not os.environ.get("DEEPSEEK_API_KEY"):
        sys.exit("Set DEEPSEEK_API_KEY in .env (root) or the environment — get one at https://platform.deepseek.com.")
    force = "--force" in sys.argv
    en = json.loads(EN.read_text(encoding="utf-8"))

    failures = []
    for code, name in LANGS.items():
        path = I18N / (code + ".json")
        cur = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        todo = {k: v for k, v in en.items() if force or k not in cur}
        if not todo:
            print("ok   %s — already complete (%d keys)" % (code, len(cur)))
            continue
        print("...  %s — translating %d key(s)" % (code, len(todo)))
        keys = list(todo)
        ok = True
        for i in range(0, len(keys), BATCH):
            chunk = {k: todo[k] for k in keys[i:i + BATCH]}
            res = translate_batch(name, chunk)
            if res is None:
                ok = False
                break
            cur.update(res)
        if ok:
            ordered = {k: cur[k] for k in en if k in cur}
            ordered.update({k: v for k, v in cur.items() if k not in en})
            path.write_text(json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print("ok   %s — wrote %d keys" % (code, len(ordered)))
        else:
            failures.append(code)
            print("FAIL %s — left unchanged" % code)

    print("\nDone. %d/%d languages updated." % (len(LANGS) - len(failures), len(LANGS)))
    if failures:
        print("Re-run to retry: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
