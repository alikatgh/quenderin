#!/usr/bin/env python3
"""Verify sampling defaults stay aligned with shared/sampling-profiles.json.

The chat + agent decode recipes are hand-ported into Swift GenerationOptions /
Android LlamaEngine + InferenceEngine defaults / AgentLoop option constants.
Edit one platform and forget the others → silently different quality. This
script is the guardrail: it loads the canonical JSON and asserts key numbers
appear in each source as the documented defaults.

Usage:  python3 scripts/check_sampling_parity.py   # exit 0 = ok, 1 = drift
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CANONICAL = ROOT / "shared" / "sampling-profiles.json"

SWIFT_GEN = ROOT / "apple/QuenderinKit/Sources/QuenderinKit/InferenceEngine.swift"
SWIFT_LOOP = ROOT / "apple/QuenderinKit/Sources/QuenderinKit/AgentLoop.swift"
KT_ENGINE = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core/LlamaEngine.kt"
KT_IFACE = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core/InferenceEngine.kt"
KT_LOOP = ROOT / "android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentLoop.kt"
JNI = ROOT / "android/jni/llama_jni.cpp"


def fail(msg: str) -> None:
    print(f"  FAIL  {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


def must_match(label: str, path: Path, patterns: list[str]) -> None:
    if not path.exists():
        fail(f"{label}: missing file {path.relative_to(ROOT)}")
    text = path.read_text(encoding="utf-8")
    for pat in patterns:
        if not re.search(pat, text):
            fail(f"{label}: pattern not found in {path.relative_to(ROOT)}: {pat}")
    ok(f"{label}: {path.relative_to(ROOT)} matches")


def main() -> None:
    if not CANONICAL.exists():
        fail(f"canonical missing: {CANONICAL}")
    prof = json.loads(CANONICAL.read_text(encoding="utf-8"))
    chat = prof["chat"]
    decision = prof["agent_decision"]
    think = prof["agent_deliberation"]

    print("Sampling parity vs shared/sampling-profiles.json")
    print(f"  chat={chat}")
    print(f"  agent_decision={decision}")
    print(f"  agent_deliberation={think}")

    # Chat defaults — Swift GenerationOptions init
    must_match(
        "iOS chat GenerationOptions",
        SWIFT_GEN,
        [
            rf"maxTokens:\s*Int\s*=\s*{chat['max_tokens']}",
            rf"temperature:\s*Double\s*=\s*{chat['temperature']}",
            rf"topP:\s*Double\s*=\s*{chat['top_p']}",
            rf"topK:\s*Int\s*=\s*{chat['top_k']}",
            rf"repeatPenalty:\s*Double\s*=\s*{chat['repeat_penalty']}",
            rf"repeatLastN:\s*Int\s*=\s*{chat['repeat_last_n']}",
        ],
    )

    # Agent decision / deliberation — Swift AgentLoop
    must_match(
        "iOS agent decision options",
        SWIFT_LOOP,
        [
            rf"maxTokens:\s*{decision['max_tokens']}",
            rf"topP:\s*{decision['top_p']}",
            rf"topK:\s*{decision['top_k']}",
            # decisionOptions and planningOptions and deliberation
            rf"temperature:\s*{think['temperature']}",
            rf"maxTokens:\s*{think['max_tokens']}",
        ],
    )

    # Android chat LlamaEngine constructor defaults
    must_match(
        "Android chat LlamaEngine",
        KT_ENGINE,
        [
            rf"maxTokens:\s*Int\s*=\s*{chat['max_tokens']}",
            rf"temperature:\s*Double\s*=\s*{chat['temperature']}",
            rf"topP:\s*Double\s*=\s*{chat['top_p']}",
        ],
    )

    # Android chat JNI penalties (load-time sampler)
    must_match(
        "Android JNI chat penalties",
        JNI,
        [
            rf"kRepeatPenalty\s*=\s*{chat['repeat_penalty']}f",
            rf"kRepeatLastN\s*=\s*{chat['repeat_last_n']}",
            # chat top_k from profile
            rf"kChatTopK\s*=\s*{chat['top_k']}",
        ],
    )

    # Android agent completeWithGrammar defaults + AgentLoop call sites
    must_match(
        "Android agent completeWithGrammar defaults",
        KT_IFACE,
        [
            rf"topP:\s*Float\s*=\s*{decision['top_p']}f",
            rf"topK:\s*Int\s*=\s*{decision['top_k']}",
            rf"temperature:\s*Float\s*=\s*{decision['temperature']}f",
            rf"repeatPenalty:\s*Float\s*=\s*{decision['repeat_penalty']}f",
            rf"repeatLastN:\s*Int\s*=\s*{decision['repeat_last_n']}",
        ],
    )

    must_match(
        "Android AgentLoop decision/think token budgets",
        KT_LOOP,
        [
            rf"completeWithGrammar\([^)]*maxTokens\s*=\s*{decision['max_tokens']}",
            rf"completeThinking\([^)]*{think['max_tokens']}",
        ],
    )

    print("ALL SAMPLING PARITY CHECKS PASSED")


if __name__ == "__main__":
    main()
