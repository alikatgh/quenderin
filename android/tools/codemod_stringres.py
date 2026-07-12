#!/usr/bin/env python3
"""
codemod_stringres.py — replace hardcoded Compose literals with stringResource(R.string.id).

Only rewrites NON-interpolated literals, and only on lines that call a localizable
Compose API (Text/*Button/label=/placeholder=/contentDescription=/title=) — so a
bare "Share" in non-UI code is never touched. Interpolated strings are left for a
manual pass. Adds the stringResource + R imports to any file it changed.
Prints a per-file report; run from android/, then `git diff` before building.
"""
import re, os, sys, glob

# english -> resource id, DERIVED from gen_strings.RES (the single source of truth — no hand copy
# to drift). Interpolated ids (%1$s/%1$d) can't be a bare stringResource() call, so they're skipped.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_strings import RES  # importing runs its load + guards but writes nothing (generation is under main())
IDMAP = {en: rid for rid, en in RES.items() if "%" not in en}

# Keep this alternation identical to extract_strings.APIS's core (the inventory tool) — both gate on
# "this line calls a localizable Compose API".
API = re.compile(r'(?:\bText|\bButton|\bOutlinedButton|\bTextButton|\bFilledTonalButton|label\s*=|placeholder\s*=|contentDescription\s*=|title\s*=)')
IMPORT_SR = "import androidx.compose.ui.res.stringResource"
IMPORT_R = "import ai.quenderin.app.R"

# Same file set as extract_strings.py: the ui/ package AND the app package root (MainActivity etc.).
files = sorted(glob.glob("app/src/main/kotlin/ai/quenderin/app/ui/*.kt")) + \
        sorted(glob.glob("app/src/main/kotlin/ai/quenderin/app/*.kt"))
total = 0
for path in files:
    lines = open(path, encoding="utf-8").read().split("\n")
    changed = 0
    for i, line in enumerate(lines):
        if not API.search(line):
            continue
        for en, rid in IDMAP.items():
            lit = '"' + en.replace("\\", "\\\\") + '"'
            # exact literal, not a substring of a longer literal or a $-template
            if lit in line and "$" not in line[line.find(lit):line.find(lit)+len(lit)+2]:
                lines[i] = line.replace(lit, f"stringResource(R.string.{rid})")
                line = lines[i]
                changed += 1
    if changed:
        src = "\n".join(lines)
        # add imports after the package line if missing. re.MULTILINE so ^package matches even when
        # the file opens with a @file:OptIn(...) annotation before the package declaration.
        if IMPORT_SR not in src:
            src = re.sub(r'(^package [^\n]+\n)', r'\1\n' + IMPORT_SR + "\n" + IMPORT_R + "\n", src, count=1, flags=re.MULTILINE)
        elif IMPORT_R not in src:
            src = re.sub(r'(^package [^\n]+\n)', r'\1\n' + IMPORT_R + "\n", src, count=1, flags=re.MULTILINE)
        open(path, "w", encoding="utf-8").write(src)
        print(f"{os.path.basename(path)}: {changed} replaced")
        total += changed
print(f"total: {total} replacements")
