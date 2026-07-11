#!/usr/bin/env python3
"""
extract_strings.py — inventory Compose string literals in the Android UI so they
can be moved into res/values/strings.xml.

For each string literal passed to a localizable Compose API (Text, *Button,
label=, placeholder=, contentDescription=, title=), report:
  file : line : has_interpolation : raw

Kotlin string templates ($x / ${expr}) are flagged so they get %1$s/%1$d format
resources (and stringResource(id, arg) call sites) instead of a plain lookup.
This is inventory only — it does not rewrite. Run from android/.
"""
import re, glob, sys

APIS = re.compile(r'(?:\bText|\bButton|\bOutlinedButton|\bTextButton|\bFilledTonalButton|label\s*=|placeholder\s*=|contentDescription\s*=|title\s*=)\s*\(?\s*"')
# a Kotlin string literal body (no raw strings), allowing escapes and $templates
LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
TEMPLATE = re.compile(r'\$\w+|\$\{[^}]+\}')

files = sorted(glob.glob("app/src/main/kotlin/ai/quenderin/app/ui/*.kt")) + \
        sorted(glob.glob("app/src/main/kotlin/ai/quenderin/app/*.kt"))

rows = []
for path in files:
    src = open(path, encoding="utf-8").read().split("\n")
    for i, line in enumerate(src, 1):
        for m in APIS.finditer(line):
            lit = LIT.search(line, m.end() - 1)
            if not lit:
                continue
            s = lit.group(1)
            if len(s) < 2 or re.fullmatch(r'[\s\W\d]*', s):
                continue
            interp = bool(TEMPLATE.search(s))
            rows.append((path.split("/")[-1], i, interp, s))

print(f"# {len(rows)} localizable literals ({sum(1 for r in rows if r[2])} interpolated)\n")
for f, ln, interp, s in rows:
    print(f"{'T' if interp else '.'} {f}:{ln}\t{s}")
