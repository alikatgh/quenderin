#!/usr/bin/env python3
"""
extract_ui_strings.py — inventory every SwiftUI LocalizedStringKey literal in the
Apple sources (QuenderinKit views + app) so Localizable.xcstrings can be generated.

Extracts string literals passed to the LocalizedStringKey-taking APIs:
  Text("..."), Button("..."), Toggle("..."), Label("...", ...), Section("..."),
  TextField("...", ...), navigationTitle("..."), confirmationDialog("..."),
  alert("..."), Menu("..."), Picker("...", ...), Link("...", ...)

Interpolated literals are reported with \\(expr) converted to positional %@ so a
human (or Claude) can decide the final format key. Verbatim `Text(variable)` is
out of scope (needs String(localized:) at the definition site).

Usage: python3 scripts/extract_ui_strings.py > /tmp/ui_strings.txt
"""
import re, glob, json, sys, os

ROOT = os.path.join(os.path.dirname(__file__), "..", "apple")
FILES = sorted(glob.glob(os.path.join(ROOT, "QuenderinKit/Sources/QuenderinKit/*.swift"))) + \
        sorted(glob.glob(os.path.join(ROOT, "QuenderinApp/Sources/*.swift")))

APIS = r'(?:Text|Button|Toggle|Label|Section|TextField|SecureField|Menu|Picker|Link|LabeledContent|navigationTitle|confirmationDialog|alert|help|accessibilityLabel|ContentUnavailableView)'
# a Swift string literal with escapes, non-greedy, no raw strings
LIT = r'"((?:[^"\\]|\\.)*)"'
PAT = re.compile(APIS + r'\(\s*' + LIT)

keys = {}
for path in FILES:
    src = open(path, encoding="utf-8").read()
    base = os.path.basename(path)
    for m in PAT.finditer(src):
        s = m.group(1)
        if not s or s in ("", " "):  # empty labels (hidden)
            continue
        if re.fullmatch(r'[\d\s.,:%+-]*', s):  # pure numeric/punct
            continue
        if s.startswith("chevron") or s.startswith("arrow") or ("." in s and " " not in s and s.islower()):
            continue  # SF Symbol names / dotted ids
        keys.setdefault(s, set()).add(base)

for s in sorted(keys):
    print(f"{s}\t{','.join(sorted(keys[s]))}")
print(f"\n# total keys: {len(keys)}", file=sys.stderr)
