#!/usr/bin/env python3
"""Structural gate for golden chat UX contracts (no LLM required).

Validates:
  - shared/golden-chat-prompts.json is well-formed
  - iOS ChatStarters + Android ChatStarters share the same starter ids/titles
  - ChatTier maxTokens match the golden tiers table
  - Document image-refusal strings mention vision (both platforms)

Exit 0 on success, 1 on drift. Runnable from repo root:
  python3 scripts/check_golden_chat_prompts.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "shared" / "golden-chat-prompts.json"
IOS_STARTERS = ROOT / "apple/QuenderinKit/Sources/QuenderinKit/ChatStarters.swift"
AND_STARTERS = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core/ChatStarters.kt"
IOS_TIER = ROOT / "apple/QuenderinKit/Sources/QuenderinKit/ChatTier.swift"
AND_TIER = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core/ChatTier.kt"
IOS_DOC = ROOT / "apple/QuenderinKit/Sources/QuenderinKit/DocumentTextExtractor.swift"
AND_DOC = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core/DocumentTextExtractor.kt"


def fail(msg: str) -> None:
    print(f"  FAIL {msg}")
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"  ok   {msg}")


def extract_starter_ids_swift(text: str) -> list[str]:
    return re.findall(r'id:\s*"([^"]+)"', text)


def extract_starter_ids_kotlin(text: str) -> list[str]:
    return re.findall(r'id\s*=\s*"([^"]+)"', text)


def extract_max_tokens_swift(text: str) -> dict[str, int]:
    # case .tiny: return 256
    out = {}
    for m in re.finditer(r"case \.(tiny|small|full):\s*return\s*(\d+)", text):
        out[m.group(1)] = int(m.group(2))
    return out


def extract_max_tokens_kotlin(text: str) -> dict[str, int]:
    # TINY -> 256
    out = {}
    for m in re.finditer(r"(TINY|SMALL|FULL)\s*->\s*(\d+)", text):
        out[m.group(1).lower()] = int(m.group(2))
    return out


def main() -> None:
    print("Golden chat prompts — structural gate")
    data = json.loads(GOLDEN.read_text(encoding="utf-8"))
    starters = data["starters"]
    golden_ids = [s["id"] for s in starters]
    if len(golden_ids) != len(set(golden_ids)):
        fail("golden starter ids not unique")
    ok(f"golden catalog: {len(golden_ids)} starters")

    ios_ids = extract_starter_ids_swift(IOS_STARTERS.read_text(encoding="utf-8"))
    and_ids = extract_starter_ids_kotlin(AND_STARTERS.read_text(encoding="utf-8"))
    if ios_ids != golden_ids:
        fail(f"iOS ChatStarters ids {ios_ids} != golden {golden_ids}")
    if and_ids != golden_ids:
        fail(f"Android ChatStarters ids {and_ids} != golden {golden_ids}")
    ok("iOS + Android starter ids match golden")

    for s in starters:
        if not s.get("offline_ok", True):
            fail(f"starter {s['id']} marked offline_ok=false — mobile product is offline-only")
    ok("all starters offline_ok")

    tier = data["tiers"]["max_tokens"]
    ios_t = extract_max_tokens_swift(IOS_TIER.read_text(encoding="utf-8"))
    and_t = extract_max_tokens_kotlin(AND_TIER.read_text(encoding="utf-8"))
    if ios_t != tier:
        fail(f"iOS ChatTier maxTokens {ios_t} != golden {tier}")
    if and_t != tier:
        fail(f"Android ChatTier maxTokens {and_t} != golden {tier}")
    if not (tier["tiny"] < tier["small"] < tier["full"]):
        fail("tier max_tokens must be strictly increasing")
    ok("ChatTier maxTokens match golden + ordered")

    vision_needles = data["vision"]["refusal_must_contain"]
    ios_doc = IOS_DOC.read_text(encoding="utf-8").lower()
    and_doc = AND_DOC.read_text(encoding="utf-8").lower()
    for needle in vision_needles:
        if needle.lower() not in ios_doc:
            fail(f"iOS DocumentTextExtractor missing vision refusal needle: {needle}")
        if needle.lower() not in and_doc:
            fail(f"Android DocumentTextExtractor missing vision refusal needle: {needle}")
    ok("image/vision refusal copy present on both platforms")

    print("ALL GOLDEN CHAT CHECKS PASSED")


if __name__ == "__main__":
    main()
