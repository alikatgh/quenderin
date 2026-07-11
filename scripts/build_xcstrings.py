#!/usr/bin/env python3
"""
build_xcstrings.py — compile scripts/translations.tsv into
apple/QuenderinApp/Localizable.xcstrings (Apple String Catalog JSON).

TSV columns (tab-separated): en_key <TAB> ru <TAB> ko <TAB> ja <TAB> zh-Hans
- en is the source language (the key itself is the English copy).
- Swift interpolations must already be in format-specifier form (%@ / %lld) in
  ALL columns — the generator validates that every translation carries the same
  multiset of specifiers as the key (a mismatched %@ crashes at render).
- Lines starting with # and blank lines are skipped.

Usage: python3 scripts/build_xcstrings.py
"""
import json, re, sys, os

ROOT = os.path.join(os.path.dirname(__file__), "..")
TSV = os.path.join(ROOT, "scripts", "translations.tsv")
OUT = os.path.join(ROOT, "apple", "QuenderinApp", "Localizable.xcstrings")
LANGS = ["ru", "ko", "ja", "zh-Hans"]

SPEC = re.compile(r'%(?:lld|@|d|\.\d+f|f|%)')

def specs(s):
    return sorted(SPEC.findall(s.replace("%%", "")))

strings = {}
errors = []
for lineno, line in enumerate(open(TSV, encoding="utf-8"), 1):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    cols = line.split("\t")
    if len(cols) != 5:
        errors.append(f"line {lineno}: expected 5 columns, got {len(cols)}")
        continue
    key, ru, ko, ja, zh = cols
    ks = specs(key)
    entry = {"localizations": {}}
    for lang, val in zip(LANGS, (ru, ko, ja, zh)):
        if not val:
            continue
        if specs(val) != ks:
            errors.append(f"line {lineno} [{lang}]: format specifiers differ from key: {val!r} vs {key!r}")
            continue
        entry["localizations"][lang] = {"stringUnit": {"state": "translated", "value": val}}
    strings[key] = entry

if errors:
    print("VALIDATION ERRORS:", file=sys.stderr)
    for e in errors:
        print(" ", e, file=sys.stderr)
    sys.exit(1)

catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
print(f"wrote {OUT}: {len(strings)} keys x up to {len(LANGS)} languages")
