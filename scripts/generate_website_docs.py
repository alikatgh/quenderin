#!/usr/bin/env python3
"""Compile Quenderin's canonical Markdown docs & shared/*.json contracts into website/docs/.

Usage:
  python3 scripts/generate_website_docs.py          # write website/docs/*.html + search-index.{json,js}
  python3 scripts/generate_website_docs.py --check  # fail if website/docs/ is stale or has broken links

Pure Python standard library — zero third-party packages or paid tooling.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import pathlib
import posixpath
import re
import sys
from dataclasses import dataclass, field
from typing import Callable

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCS_OUT = ROOT / "website" / "docs"
REPO_BLOB_BASE = "https://github.com/alikatgh/quenderin/blob/main/"
CANONICAL_BASE = "https://quenderin.org/docs/"


@dataclass(frozen=True)
class DocPage:
    slug: str            # "index" -> /docs/, others -> /docs/<slug>
    category: str
    icon: str            # .qi-* class from ../lucide-icons.css
    title: str
    kicker: str
    description: str
    sources: tuple[str, ...]
    extra_section: str | None = None  # key into EXTRA_RENDERERS
    fold_subdocs: bool = False        # fold extra appended docs after the first when True
    fold_h2: bool = False             # fold long H2 blocks (e.g. BUG_JOURNAL.md)


PAGES: tuple[DocPage, ...] = (
    # Track 1: Start Here
    DocPage(
        slug="index",
        category="Start Here",
        icon="qi-book-open",
        title="Quenderin Documentation",
        kicker="Documentation Portal",
        description="Complete user, model, inference, architecture, native platform, API, and release engineering documentation compiled from the repository.",
        sources=("docs/README.md",),
        extra_section="hub_overview",
    ),
    DocPage(
        slug="overview",
        category="Start Here",
        icon="qi-compass",
        title="Overview & Quenderin A to Z",
        kicker="Start Here · System Map",
        description="End-to-end map of Quenderin: mission, product identity, privacy boundary, platforms, and cross-platform feature status.",
        sources=("README.md", "docs/QUENDERIN_A_TO_Z.md", "docs/PRODUCT.md", "STATUS.md"),
    ),
    DocPage(
        slug="quickstart",
        category="Start Here",
        icon="qi-rocket",
        title="Quickstart, Setup & Run Guide",
        kicker="Start Here · Installation",
        description="Run the CLI, build the Electron desktop prototype and web UI, configure optional native helpers, and download verified GGUF models.",
        sources=("QUICKSTART.md", "SETUP.md", "RUN_GUIDE.md"),
    ),
    DocPage(
        slug="troubleshooting",
        category="Start Here",
        icon="qi-wrench",
        title="Troubleshooting & Device Verification",
        kicker="Start Here · Diagnostics",
        description="Fix Node/npm build failures, llama.cpp native addon issues, simulator/emulator checks, and physical-device verification runs.",
        sources=("TROUBLESHOOTING.md", "docs/DEVICE_VERIFICATION.md"),
    ),

    # Track 2: Product & Governed Agent
    DocPage(
        slug="features",
        category="Agent & Product",
        icon="qi-sliders-horizontal",
        title="Features, Shell Router & Capabilities",
        kicker="Product · Capabilities",
        description="Chat features, task routing across installed models, the compact shell UI, deep settings, and extending the governed capability registry.",
        sources=("FEATURES.md", "docs/SHELL_ROUTER_SETTINGS.md", "docs/ADDING_A_CAPABILITY.md"),
    ),
    DocPage(
        slug="cli-and-agent",
        category="Agent & Product",
        icon="qi-bot",
        title="Governed Local Agent & Autonomy",
        kicker="Agent · Plan-Approve-Undo",
        description="Dry-run planning, explicit approval, reversible file moves, Accessibility & Apple Shortcuts execution, dynamic planning, and audit logs.",
        sources=(
            "docs/AGENT_AUTONOMY_PLAN.md",
            "docs/agent-cross-platform-state.md",
            "docs/audits/2026-07-06-Q549-agent-governance-analysis.md",
            "docs/audits/2026-07-08-dynamic-planning.md",
            "docs/audits/2026-07-08-world-class-multistep.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="remote-harness",
        category="Agent & Product",
        icon="qi-lock",
        title="Native Connections, Remote Crypto & Bots",
        kicker="Agent · Remote & Extensions",
        description="Encrypted remote companion host, runtime fixture, Noise/Ed25519 crypto bridge, mobile stop parity, and external provider contracts.",
        sources=(
            "docs/native-connections-roadmap.md",
            "docs/remote-mobile-ux-implementation.md",
            "native/remote-host/README.md",
            "native/remote-host/runtime-fixture/README.md",
            "native/remote-crypto/README.md",
            "native/remote-crypto/LICENSES.md",
            "docs/deepseek-bot-integration-plan.md",
            "docs/deepseek-bot-sol-implementation.md",
        ),
        extra_section="remote_contracts",
        fold_subdocs=True,
    ),

    # Track 3: Models & Hardware Fit
    DocPage(
        slug="models-catalog",
        category="Models & Hardware",
        icon="qi-cpu",
        title="Model Catalog & Runtime Manifests",
        kicker="Models · Live Registry",
        description="All 28 curated GGUF models, RAM floors, SHA-256 verification, image models, and source-level experimental runtime manifests.",
        sources=("docs/MODEL_CATALOG_FRESHNESS.md",),
        extra_section="live_models",
    ),
    DocPage(
        slug="device-selection",
        category="Models & Hardware",
        icon="qi-hard-drive",
        title="Model Selection & Phone Hardware Fit",
        kicker="Models · Device Adaptation",
        description="How Quenderin scores device RAM and SoCs, picks Q4/Q2/Q3 quantizations per tier, and optimizes Qwen 3 and runtime parameters.",
        sources=(
            "apple/MODEL_SELECTION.md",
            "docs/audits/2026-06-20-phone-hardware-adaptation-plan.md",
            "docs/audits/2026-07-08-qwen3-runtime-optimality.md",
            "docs/audits/2026-07-08-new-features-review.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="bonsai-muse",
        category="Models & Hardware",
        icon="qi-sparkles",
        title="Bonsai 2, Prism, Muse & Diffusion",
        kicker="Models · Experimental Engines",
        description="Source-integrated 1-bit Bonsai 2 / Q1_0_G128 via Prism, Muse Spark artifact manifests, and local image diffusion runtime status.",
        sources=("docs/bonsai-2.md", "native/diffusion/README.md"),
        extra_section="experimental_engines",
    ),
    DocPage(
        slug="benchmarks-reality",
        category="Models & Hardware",
        icon="qi-gauge",
        title="Inference SLOs, Baselines & Reality",
        kicker="Performance · Measurements",
        description="Measured vs simulated throughput ceilings, latency targets (TTFT / decode TPS), thermal limits, and hardware reality checks.",
        sources=("docs/INFERENCE_SLO.md", "docs/BENCH_BASELINE.md", "apple/REALITY.md"),
        extra_section="perf_contract",
    ),

    # Track 4: Inference 101 & Acceleration
    DocPage(
        slug="inference-101",
        category="Inference Internals",
        icon="qi-flame",
        title="Inference 101: Quenderin Pipeline",
        kicker="101 Series · Foundations",
        description="How local LLM inference works end-to-end inside Quenderin: GGUF weights, tokenization, prefill vs decode, KV cache, and sampling.",
        sources=("docs/INFERENCE_101.md",),
    ),
    DocPage(
        slug="mobile-performance-101",
        category="Inference Internals",
        icon="qi-activity",
        title="Mobile Performance & KV-Cache Tuning",
        kicker="101 Series · Mobile Tuning",
        description="Memory-bandwidth limits, i8mm/dot-product kernels, thermal throttling, KV-cache context shifting, and llama.cpp mobile tuning audits.",
        sources=(
            "docs/MOBILE_PERFORMANCE_101.md",
            "docs/audits/2026-07-01-kv-cache-reuse-cliff.md",
            "docs/audits/2026-07-02-oss-audit-llamacpp-mobile.md",
        ),
    ),
    DocPage(
        slug="llama-cpp-101",
        category="Inference Internals",
        icon="qi-terminal",
        title="llama.cpp C++ Internals 101",
        kicker="101 Series · Engine Internals",
        description="Under the hood of ggml, Metal and CPU backends, tensor allocation, batch decoding, sampler chains, and abort callbacks.",
        sources=("docs/LLAMA_CPP_101.md",),
    ),
    DocPage(
        slug="npu-max-acceleration",
        category="Inference Internals",
        icon="qi-zap",
        title="NPU, Neural Engine & MAX Acceleration",
        kicker="Inference · Hardware Acceleration",
        description="Honest assessment of Apple ANE / Hexagon NPU tradeoffs for LLM decode and Modular MAX runtime bindings for Apple and Android.",
        sources=(
            "docs/NPU_NEURAL_ENGINE.md",
            "docs/modular-acceleration-plan.md",
            "docs/max-mobile-integration.md",
            "docs/max-apple-binding.md",
            "docs/max-android-binding.md",
            "native/max-runtime/README.md",
            "native/max-runtime/NOTICE.md",
        ),
        fold_subdocs=True,
    ),

    # Track 5: Architecture, API & Parity
    DocPage(
        slug="architecture",
        category="Architecture & API",
        icon="qi-layers",
        title="System Architecture",
        kicker="Architecture · Core Design",
        description="Layered TypeScript, Swift, and Kotlin architecture across chat, model management, shared contracts, and governed OS execution.",
        sources=("docs/ARCHITECTURE.md", "apple/ARCHITECTURE.md"),
    ),
    DocPage(
        slug="backend-frontend",
        category="Architecture & API",
        icon="qi-server",
        title="Backend, Dashboard UI & Website Stack",
        kicker="Architecture · Web & Services",
        description="Express backend, React UI dashboard, Cloudflare Worker website, SEO clean-URL indexing, and the optional content-report receiver.",
        sources=(
            "docs/BACKEND.md",
            "docs/FRONTEND.md",
            "ui/README.md",
            "website/README.md",
            "docs/WEBSITE_INDEXING.md",
            "services/content-report-receiver/README.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="api-reference",
        category="Architecture & API",
        icon="qi-braces",
        title="HTTP REST & WebSocket API Reference",
        kicker="Reference · Local Endpoints",
        description="Localhost HTTP endpoints, WebSocket streaming protocol, agent plan/execute/undo calls, model management routes, and error schemas.",
        sources=("docs/API.md",),
    ),
    DocPage(
        slug="cross-platform-parity",
        category="Architecture & API",
        icon="qi-git-branch",
        title="Cross-Platform Parity & Verification",
        kicker="Architecture · Contract Testing",
        description="Machine-enforced parity across TypeScript, Swift, Python, and Kotlin: twin-drift audits, router/sampling vectors, and agent loop parity.",
        sources=(
            "docs/audits/2026-07-06-twin-drift-audit.md",
            "docs/audits/2026-07-07-platform-audit.md",
            "docs/audits/2026-07-08-agent-loop-parity.md",
            "docs/audits/2026-07-06-r9-quenderin-api-contract.md",
            "docs/audits/2026-07-06-adversarial-verification.md",
        ),
        fold_subdocs=True,
    ),

    # Track 6: Platforms & Store Distribution
    DocPage(
        slug="apple-native",
        category="Platforms & Releases",
        icon="qi-apple",
        title="Apple Native: macOS, iOS & QuenderinKit",
        kicker="Platforms · Apple",
        description="Universal SwiftUI app, QuenderinKit SPM package, llama.cpp xcframework integration, Xcode Cloud bounded tests, and MLX comparison.",
        sources=(
            "apple/QuenderinKit/README.md",
            "apple/QuenderinKit/INTEGRATION.md",
            "apple/QuenderinApp/README.md",
            "apple/QuenderinApp/Tests/README.md",
            "apple/ROADMAP.md",
            "docs/audits/2026-07-02-oss-audit-mlx-swift.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="android-mobile",
        category="Platforms & Releases",
        icon="qi-smartphone",
        title="Android Native & Mobile Build",
        kicker="Platforms · Android",
        description="Jetpack Compose + JNI llama.cpp core, CPU variant selection, NDK build requirements, mobile verification, and Play signing scripts.",
        sources=(
            "android/README.md",
            "android/INTEGRATION.md",
            "android/quenderin-core/README.md",
            "docs/BUILD_MOBILE.md",
            "tools/android-release/README.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="desktop-distribution",
        category="Platforms & Releases",
        icon="qi-monitor",
        title="Desktop Platforms & Store Channels",
        kicker="Platforms · Desktop",
        description="Windows & Linux desktop strategy, Mac App Store packaging, and Microsoft Store MSIX submission workflow.",
        sources=("docs/WINDOWS_LINUX_STRATEGY.md", "docs/MAC_APP_STORE.md", "docs/MICROSOFT_STORE.md"),
    ),
    DocPage(
        slug="release-store",
        category="Platforms & Releases",
        icon="qi-package",
        title="Release Status & Store Submissions",
        kicker="Releases · Live Store Ledger",
        description="Verified App Store Connect (0.6.0 shipped Nov 1, 0.6.1 prepared) & Google Play (0.2.0 closed beta) record, checklists, and store copy.",
        sources=(
            "docs/RELEASE.md",
            "docs/SHIP_READINESS.md",
            "docs/STORE_SUBMISSION.md",
            "docs/STORE_LISTING.md",
            "LAUNCH_CHECKLIST.md",
            "docs/APPLE_LAUNCH_MATERIALS.md",
            "appstore/METADATA.md",
            "appstore/play/LISTING.md",
            "appstore/play/TESTER_RECRUITMENT.md",
            "appstore/play/GITHUB_RELEASE_NOTES.md",
            "docs/releases/2026-10-19-native-050/store-copy.md",
            "docs/releases/2026-10-28-native-060/store-copy.md",
            "docs/releases/2026-11-09-native-061/store-copy.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="security-privacy",
        category="Platforms & Releases",
        icon="qi-shield-check",
        title="Security, Privacy & Encryption Annex",
        kicker="Security · Threat Model",
        description="Vulnerability reporting, SHA-256 download integrity, local-only data policy, Apple export-compliance annex, and store compliance audit.",
        sources=(
            "SECURITY.md",
            "docs/legal/privacy-policy.md",
            "docs/releases/2026-10-28-native-060/encryption-technical-summary.md",
            "docs/audits/2026-06-16-store-compliance-audit.md",
        ),
    ),

    # Track 7: Reliability, Design, Research & Evolution
    DocPage(
        slug="failure-modes",
        category="Quality, Research & Evolution",
        icon="qi-alert-triangle",
        title="Known Failure Modes & Engineering Backlog",
        kicker="Reliability · Open Ledger",
        description="Unfiltered ledger of known limitations, urgent engineering items, cross-machine handoff notes, and the 50-round audit status.",
        sources=(
            "docs/KNOWN_FAILURE_MODES.md",
            "docs/ASAP_IMPROVEMENTS.md",
            "docs/HANDOFF.md",
            "docs/audits/ROUND-STATUS.md",
            "docs/audits/2026-08-10-quenderin-fixes.md",
            "docs/audits/2026-06-14-CONSOLIDATED-open-findings.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="bug-journal",
        category="Quality, Research & Evolution",
        icon="qi-bug",
        title="Engineering Bug Journal",
        kicker="Reliability · Post-Mortems",
        description="Chronological Q-series bug journal documenting root causes, regression pins, and cross-platform fixes across the codebase.",
        sources=("docs/BUG_JOURNAL.md",),
        fold_h2=True,
    ),
    DocPage(
        slug="brand-design",
        category="Quality, Research & Evolution",
        icon="qi-award",
        title="Brand, Design System & Visual Assets",
        kicker="Design · Typography & Tokens",
        description="Quenderin brand rules, anti-slop criteria, paper/teal/copper tokens, DINish + ChunkFive + Lucide typography, and icon pipeline.",
        sources=(
            "docs/BRAND.md",
            "docs/DESIGN_SYSTEM.md",
            "docs/ICON_EXTRACTION.md",
            "website/icons/README.md",
            "docs/audits/2026-07-11-website-audit.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="research-survey",
        category="Quality, Research & Evolution",
        icon="qi-globe",
        title="On-Device AI Research Survey",
        kicker="Research · Literature & Landscape",
        description="Verified academic and open-source benchmarks for mobile LLM inference, SSD MoE streaming (edge0), and peer local-AI projects.",
        sources=(
            "docs/research/on-device-llm.md",
            "docs/research/moe-ssd-streaming.md",
            "docs/research/similar-projects.md",
            "docs/audits/2026-06-14-r5-quenderin-research.md",
            "docs/audits/2026-07-06-r8-quenderin-research.md",
        ),
        fold_subdocs=True,
    ),
    DocPage(
        slug="development-roadmap",
        category="Quality, Research & Evolution",
        icon="qi-code-2",
        title="Development Guide, Contributing & Roadmap",
        kicker="Contributors · Workflow",
        description="Repo conventions, parity-check commands, contribution workflow, and the 4-stage technical roadmap toward local computer usage.",
        sources=("docs/DEVELOPMENT.md", "CONTRIBUTING.md", "docs/ROADMAP.md"),
    ),
    DocPage(
        slug="changelog-releases",
        category="Quality, Research & Evolution",
        icon="qi-history",
        title="Changelog & Engineering Updates",
        kicker="History · Releases",
        description="Release history from v0.1.0 through v0.6.x plus detailed October 2026 model and engineering publication records.",
        sources=(
            "CHANGELOG.md",
            "docs/social/2026-10-16-muse-bonsai/README.md",
            "docs/social/2026-10-18-open-models/README.md",
        ),
        fold_subdocs=True,
    ),
)


# Map normalized repo source paths -> (page_slug, anchor_id)
def build_source_map() -> tuple[dict[str, tuple[str, str]], dict[str, DocPage]]:
    src_to_page: dict[str, tuple[str, str]] = {}
    pages_by_slug: dict[str, DocPage] = {}
    for page in PAGES:
        pages_by_slug[page.slug] = page
        for i, src in enumerate(page.sources):
            norm = posixpath.normpath(src)
            anchor = "" if i == 0 and len(page.sources) == 1 else f"src-{slugify(norm)}"
            src_to_page[norm] = (page.slug, anchor)
    return src_to_page, pages_by_slug


def slugify(text: str) -> str:
    s = re.sub(r"<[^>]+>", "", text)
    s = html.unescape(s).strip().lower()
    s = re.sub(r"['’`]+", "", s)
    s = re.sub(r"[*_~\"()\[\]{}:;,.?!+/\\]+", "-", s)
    s = re.sub(r"[^a-z0-9-]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    return s or "section"


def sanitize_repo_text(text: str) -> str:
    # Redact developer-specific absolute checkout paths while keeping repo-relative paths.
    text = re.sub(r"/Users/[^/\s`\"')]+/Documents/projects/quenderin/", "", text)
    text = re.sub(r"/Users/[^/\s`\"')]+/Documents/projects/quenderin\b", "<repo>", text)
    text = re.sub(r"/Users/[^/\s`\"')]+/", "~/", text)
    return text


def page_href(slug: str) -> str:
    return "./" if slug == "index" else slug


def page_canonical(slug: str) -> str:
    return CANONICAL_BASE if slug == "index" else f"{CANONICAL_BASE}{slug}"


class MarkdownCompiler:
    """Clean, deterministic GFM + admonition compiler with repo-aware link rewriting."""

    def __init__(
        self,
        source_path: str,
        current_slug: str,
        src_map: dict[str, tuple[str, str]],
        used_ids: set[str],
        fold_h2: bool = False,
        base_heading_level: int = 2,
    ) -> None:
        self.source_path = posixpath.normpath(source_path)
        self.source_dir = posixpath.dirname(self.source_path)
        self.current_slug = current_slug
        self.src_map = src_map
        self.used_ids = used_ids
        self.fold_h2 = fold_h2
        self.base_heading_level = base_heading_level
        self.headings: list[dict[str, str | int]] = []
        self.plain_chunks: list[str] = []

    def unique_id(self, base: str) -> str:
        cid = slugify(base)
        if cid not in self.used_ids:
            self.used_ids.add(cid)
            return cid
        idx = 2
        while f"{cid}-{idx}" in self.used_ids:
            idx += 1
        out = f"{cid}-{idx}"
        self.used_ids.add(out)
        return out

    def resolve_link(self, raw_url: str) -> tuple[str, bool]:
        url = raw_url.strip()
        if not url:
            return "#", False
        if url.startswith(("mailto:", "tel:")):
            return url, False
        if url.startswith(("http://", "https://")):
            return url, True
        if url.startswith("#"):
            return url, False

        path_part, _, frag = url.partition("#")
        path_part = path_part.split("?", 1)[0]
        if path_part.startswith("/"):
            repo_rel = posixpath.normpath(path_part.lstrip("/"))
        else:
            joined = posixpath.join(self.source_dir, path_part) if self.source_dir else path_part
            repo_rel = posixpath.normpath(joined)

        if repo_rel.startswith(".."):
            return REPO_BLOB_BASE + repo_rel.lstrip("./"), True

        # Website HTML targets
        if repo_rel.startswith("website/") and repo_rel.endswith(".html"):
            web_name = repo_rel[len("website/"):]
            clean_web = "" if web_name == "index.html" else web_name[:-5]
            return f"../{clean_web}" + (f"#{frag}" if frag else ""), False

        if repo_rel in self.src_map:
            target_slug, default_anchor = self.src_map[repo_rel]
            anchor = frag or default_anchor
            if target_slug == self.current_slug:
                return f"#{anchor}" if anchor else "#", False
            base = page_href(target_slug)
            return (f"{base}#{anchor}" if anchor else base), False

        # Fallback: point to canonical GitHub blob/tree if file exists in repo
        candidate = ROOT / repo_rel
        if candidate.is_dir():
            return f"https://github.com/alikatgh/quenderin/tree/main/{repo_rel}", True
        if candidate.exists():
            suffix = f"#{frag}" if frag else ""
            return f"{REPO_BLOB_BASE}{repo_rel}{suffix}", True

        return f"https://github.com/alikatgh/quenderin/blob/main/{repo_rel}", True

    def format_inline(self, text: str) -> str:
        # 1. Protect inline code spans with placeholder tokens so emphasis/links never corrupt identifiers.
        code_tokens: list[str] = []

        def repl_code(m: re.Match[str]) -> str:
            idx = len(code_tokens)
            code_tokens.append(f"<code>{html.escape(m.group(2))}</code>")
            return f"\x00CODE{idx}\x00"

        s = re.sub(r"(`+)([^`]*?)\1", repl_code, text)

        # 2. Protect images and links
        link_tokens: list[str] = []

        def store_token(rendered: str) -> str:
            idx = len(link_tokens)
            link_tokens.append(rendered)
            return f"\x00LINK{idx}\x00"

        def repl_image(m: re.Match[str]) -> str:
            alt = html.escape(m.group(1))
            src = m.group(2).strip()
            if src.startswith("website/"):
                src = "../" + src[len("website/"):]
            elif not src.startswith(("http://", "https://", "data:")):
                repo_rel = posixpath.normpath(posixpath.join(self.source_dir, src) if self.source_dir else src)
                if repo_rel.startswith("website/"):
                    src = "../" + repo_rel[len("website/"):]
                else:
                    src = f"https://raw.githubusercontent.com/alikatgh/quenderin/main/{repo_rel}"
            return store_token(f'<img src="{html.escape(src, quote=True)}" alt="{alt}" loading="lazy" />')

        s = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", repl_image, s)

        def repl_link(m: re.Match[str]) -> str:
            label_raw = m.group(1)
            href_raw = m.group(2)
            href, is_ext = self.resolve_link(href_raw)
            label_html = self.format_inline_no_links(label_raw, code_tokens)
            if is_ext:
                return store_token(
                    f'<a href="{html.escape(href, quote=True)}" rel="noopener" target="_blank">'
                    f'{label_html}<span class="qi qi-arrow-up-right" aria-hidden="true" style="font-size:0.8em;margin-left:0.15rem"></span></a>'
                )
            return store_token(f'<a href="{html.escape(href, quote=True)}">{label_html}</a>')

        # Handle links cleanly even when alt/label has escaped chars or inline code placeholders
        s = re.sub(r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(([^)\s]+(?:\s+\"[^\"]*\")?)\)", lambda m: repl_link_wrapper(m), s)

        def repl_autolink(m: re.Match[str]) -> str:
            url = m.group(1)
            esc = html.escape(url, quote=True)
            return store_token(f'<a href="{esc}" rel="noopener" target="_blank">{html.escape(url)}</a>')

        # Autolinks <https://...>
        s = re.sub(r"<(https?://[^>]+)>", repl_autolink, s)

        # Preserve <kbd>...</kbd>, <br>, <sub>, <sup> safely
        kbd_tokens: list[str] = []

        def repl_kbd(m: re.Match[str]) -> str:
            idx = len(kbd_tokens)
            kbd_tokens.append(f"<kbd>{html.escape(m.group(1))}</kbd>")
            return f"\x00KBD{idx}\x00"

        s = re.sub(r"<kbd>(.*?)</kbd>", repl_kbd, s, flags=re.I)

        # Escape HTML outside our protected placeholders
        s = html.escape(s, quote=False)

        # Inline styles (bold, italic, strikethrough)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"__(.+?)__", r"<strong>\1</strong>", s)
        s = re.sub(r"~~(.+?)~~", r"<del>\1</del>", s)
        s = re.sub(r"(?<![A-Za-z0-9])\*([^\s*](?:.*?[^\s*])?)\*(?![A-Za-z0-9])", r"<em>\1</em>", s)
        s = re.sub(r"(?<![A-Za-z0-9/])_([^\s_](?:.*?[^\s_])?)_(?![A-Za-z0-9/])", r"<em>\1</em>", s)

        # Restore tokens
        for idx, val in enumerate(kbd_tokens):
            s = s.replace(f"\x00KBD{idx}\x00", val)
        for idx, val in enumerate(link_tokens):
            s = s.replace(f"\x00LINK{idx}\x00", val)
        for idx, val in enumerate(code_tokens):
            s = s.replace(f"\x00CODE{idx}\x00", val)
        return s

    def format_inline_no_links(self, text: str, code_tokens: list[str]) -> str:
        s = html.escape(text, quote=False)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<![A-Za-z0-9])\*([^\s*](?:.*?[^\s*])?)\*(?![A-Za-z0-9])", r"<em>\1</em>", s)
        for idx, val in enumerate(code_tokens):
            s = s.replace(f"\x00CODE{idx}\x00", val)
        return s

    def compile(self, raw_md: str) -> str:
        text = sanitize_repo_text(raw_md).replace("\r\n", "\n")
        # Strip YAML frontmatter if present at top
        if text.startswith("---\n"):
            m = re.match(r"^---\n.*?\n---\n", text, re.S)
            if m:
                text = text[m.end():]

        lines = text.split("\n")
        # Skip duplicate leading H1 when compiling single-heading blocks whose H1 matches subdoc banner
        out, _ = self._parse_blocks(lines, allow_h2_fold=self.fold_h2)
        return out

    def _parse_blocks(self, lines: list[str], allow_h2_fold: bool = False) -> tuple[str, int]:
        blocks: list[str] = []
        i = 0
        n = len(lines)
        fold_open = False

        def close_fold() -> None:
            nonlocal fold_open
            if fold_open:
                blocks.append("</div></details>")
                fold_open = False

        while i < n:
            line = lines[i]
            stripped = line.strip()

            if not stripped:
                i += 1
                continue

            # Fenced code block (``` or ~~~, supporting >=3 chars)
            m_fence = re.match(r"^(\s*)(`{3,}|~{3,})(.*)$", line)
            if m_fence:
                fence_char = m_fence.group(2)[0]
                fence_len = len(m_fence.group(2))
                lang = m_fence.group(3).strip().split()[0] if m_fence.group(3).strip() else "text"
                code_lines: list[str] = []
                i += 1
                close_rx = re.compile(rf"^\s*{re.escape(fence_char)}{{{fence_len},}}\s*$")
                while i < n and not close_rx.match(lines[i]):
                    code_lines.append(lines[i])
                    i += 1
                if i < n:
                    i += 1
                code_str = html.escape("\n".join(code_lines))
                lang_esc = html.escape(lang)
                blocks.append(
                    f'<div class="docs-codeblock">'
                    f'<div class="docs-codeblock-bar">'
                    f'<span class="docs-code-lang"><span class="qi qi-terminal" aria-hidden="true"></span>{lang_esc}</span>'
                    f'<button class="docs-copy-btn" type="button"><span class="qi qi-copy" aria-hidden="true"></span><span>Copy</span></button>'
                    f'</div>'
                    f'<pre><code>{code_str}</code></pre>'
                    f'</div>'
                )
                self.plain_chunks.append("\n".join(code_lines)[:300])
                continue

            # Headings (# .. ######)
            m_h = re.match(r"^(#{1,6})\s+(.+?)\s*#*$", line)
            if m_h:
                raw_lvl = len(m_h.group(1))
                # Map source H1 -> base_heading_level (2), H2 -> 2 (or 3 if H1 kept), clamp 2..4 visually cleanly:
                # If doc has H1 only at line 1 it was handled cleanly or promoted so page keeps one <h1>.
                lvl = min(max(raw_lvl + (self.base_heading_level - 1) if raw_lvl > 1 else self.base_heading_level, 2), 5)
                heading_text = m_h.group(2).strip()
                m_anchor = re.search(r'<a\s+(?:name|id)=["\']([^"\']+)["\']\s*>\s*</a>', heading_text, re.I)
                explicit_id = m_anchor.group(1).strip() if m_anchor else None
                if m_anchor:
                    heading_text = re.sub(r'<a\s+(?:name|id)=["\'][^"\']+["\']\s*>\s*</a>', "", heading_text, flags=re.I).strip()
                hid = self.unique_id(explicit_id or heading_text)
                inline = self.format_inline(heading_text)
                clean_text = re.sub(r"<[^>]+>", "", inline)
                self.plain_chunks.append(clean_text)

                if allow_h2_fold and raw_lvl == 2:
                    close_fold()
                    self.headings.append({"id": hid, "text": html.unescape(clean_text), "level": 2})
                    blocks.append(
                        f'<details class="docs-fold">'
                        f'<summary id="{hid}"><span>{inline}</span><span class="qi qi-chevron-down" aria-hidden="true"></span></summary>'
                        f'<div class="docs-fold-body">'
                    )
                    fold_open = True
                    i += 1
                    continue

                if lvl in (2, 3):
                    self.headings.append({"id": hid, "text": html.unescape(clean_text), "level": lvl})
                blocks.append(
                    f'<h{lvl} id="{hid}">{inline}'
                    f'<a class="docs-heading-anchor" href="#{hid}" aria-label="Link to section">'
                    f'<span class="qi qi-link" aria-hidden="true"></span></a></h{lvl}>'
                )
                i += 1
                continue

            # Horizontal rule
            if re.match(r"^\s*([-*_])(?:\s*\1){2,}\s*$", line):
                blocks.append("<hr />")
                i += 1
                continue

            # Passthrough HTML <details> / </details> blocks when author wrote them intentionally
            if stripped.startswith(("<details", "</details>", "<summary")):
                blocks.append(line)
                i += 1
                continue

            # Blockquote / GitHub Alert
            if line.lstrip().startswith(">"):
                qlines: list[str] = []
                while i < n and lines[i].lstrip().startswith(">"):
                    q = re.sub(r"^\s*>\s?", "", lines[i])
                    qlines.append(q)
                    i += 1
                if qlines:
                    m_alert = re.match(r"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$", qlines[0].strip(), re.I)
                    if m_alert:
                        kind = m_alert.group(1).lower()
                        first_rest = m_alert.group(2).strip()
                        body_lines = ([first_rest] if first_rest else []) + qlines[1:]
                        icon_map = {
                            "note": "qi-info",
                            "tip": "qi-lightbulb",
                            "important": "qi-alert-triangle",
                            "warning": "qi-triangle-alert",
                            "caution": "qi-shield-alert",
                        }
                        sub_compiler = MarkdownCompiler(
                            self.source_path, self.current_slug, self.src_map, self.used_ids, False, self.base_heading_level
                        )
                        inner_html, _ = sub_compiler._parse_blocks(body_lines, allow_h2_fold=False)
                        self.headings.extend(sub_compiler.headings)
                        self.plain_chunks.extend(sub_compiler.plain_chunks)
                        blocks.append(
                            f'<aside class="docs-callout docs-callout--{kind}">'
                            f'<div class="docs-callout-title"><span class="qi {icon_map[kind]}" aria-hidden="true"></span>{kind.upper()}</div>'
                            f'<div class="docs-callout-body">{inner_html}</div>'
                            f'</aside>'
                        )
                    else:
                        sub_compiler = MarkdownCompiler(
                            self.source_path, self.current_slug, self.src_map, self.used_ids, False, self.base_heading_level
                        )
                        inner_html, _ = sub_compiler._parse_blocks(qlines, allow_h2_fold=False)
                        self.plain_chunks.extend(sub_compiler.plain_chunks)
                        blocks.append(f"<blockquote>{inner_html}</blockquote>")
                continue

            # Pipe table (header row + separator row |---|---|)
            if (
                "|" in line
                and i + 1 < n
                and "|" in lines[i + 1]
                and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1].strip())
            ):
                headers = split_table_row(line)
                aligns = parse_table_aligns(lines[i + 1], len(headers))
                i += 2
                rows: list[list[str]] = []
                while i < n and lines[i].strip() and "|" in lines[i] and not lines[i].lstrip().startswith((">", "#")):
                    rows.append(split_table_row(lines[i]))
                    i += 1
                th_html = "".join(
                    f'<th{f" style=\"text-align:{a}\"" if a else ""}>{self.format_inline(h)}</th>'
                    for h, a in zip(headers, aligns)
                )
                tr_list: list[str] = []
                for row in rows:
                    padded = row + [""] * max(0, len(headers) - len(row))
                    tds = "".join(
                        f'<td{f" style=\"text-align:{a}\"" if a else ""}>{self.format_inline(cell)}</td>'
                        for cell, a in zip(padded[: len(headers)], aligns)
                    )
                    tr_list.append(f"<tr>{tds}</tr>")
                    plain_row = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", " ".join(row)).replace("`", "")
                    self.plain_chunks.append(plain_row)
                blocks.append(
                    f'<div class="docs-table-wrap"><table>'
                    f"<thead><tr>{th_html}</tr></thead>"
                    f"<tbody>{''.join(tr_list)}</tbody>"
                    f"</table></div>"
                )
                continue

            # Unordered or Ordered list (supporting nesting via indent stack)
            m_li = re.match(r"^(\s*)(?:([-*+])|(\d+[.)]))\s+(.*)$", line)
            if m_li:
                list_html, i = self._parse_list(lines, i)
                blocks.append(list_html)
                continue

            # Paragraph (coalesce consecutive plain lines)
            para_lines: list[str] = [stripped]
            i += 1
            while i < n:
                nxt = lines[i]
                nst = nxt.strip()
                if not nst:
                    break
                if (
                    re.match(r"^(\s*)(`{3,}|~{3,})", nxt)
                    or re.match(r"^#{1,6}\s+", nxt)
                    or nxt.lstrip().startswith(">")
                    or re.match(r"^\s*([-*_])(?:\s*\1){2,}\s*$", nxt)
                    or re.match(r"^(\s*)(?:([-*+])|(\d+[.)]))\s+", nxt)
                    or nst.startswith(("<details", "</details>", "<summary"))
                    or ("|" in nxt and i + 1 < n and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1].strip()))
                ):
                    break
                para_lines.append(nst)
                i += 1
            joined = " ".join(para_lines)
            inline = self.format_inline(joined)
            self.plain_chunks.append(re.sub(r"<[^>]+>", "", inline))
            blocks.append(f"<p>{inline}</p>")

        close_fold()
        return "\n".join(blocks), i

    def _parse_list(self, lines: list[str], start: int) -> tuple[str, int]:
        n = len(lines)
        i = start
        m0 = re.match(r"^(\s*)(?:([-*+])|(\d+[.)]))\s+(.*)$", lines[i])
        assert m0 is not None
        base_indent = len(m0.group(1).replace("\t", "  "))
        is_ol = bool(m0.group(3))
        tag = "ol" if is_ol else "ul"
        items: list[str] = []

        while i < n:
            line = lines[i]
            if not line.strip():
                # Peek ahead to see if same list continues after blank line
                j = i + 1
                while j < n and not lines[j].strip():
                    j += 1
                if j < n:
                    mj = re.match(r"^(\s*)(?:([-*+])|(\d+[.)]))\s+", lines[j])
                    if mj and len(mj.group(1).replace("\t", "  ")) >= base_indent:
                        i = j
                        continue
                break

            m = re.match(r"^(\s*)(?:([-*+])|(\d+[.)]))\s+(.*)$", line)
            if not m:
                break
            indent = len(m.group(1).replace("\t", "  "))
            item_is_ol = bool(m.group(3))
            if indent < base_indent or (indent == base_indent and item_is_ol != is_ol):
                break
            if indent > base_indent:
                sub_html, i = self._parse_list(lines, i)
                if items:
                    items[-1] = items[-1][:-5] + "\n" + sub_html + "</li>"
                else:
                    items.append(f"<li>{sub_html}</li>")
                continue

            item_text_lines = [m.group(4).strip()]
            i += 1
            # Collect wrapped continuation lines at indent > base_indent (not a new list marker or fence)
            while i < n and lines[i].strip():
                nxt = lines[i]
                nxt_indent = len(nxt[: len(nxt) - len(nxt.lstrip(" \t"))].replace("\t", "  "))
                if nxt_indent > base_indent and not re.match(r"^\s*(?:[-*+]|\d+[.)])\s+", nxt) and not re.match(r"^\s*(`{3,}|~{3,})", nxt):
                    item_text_lines.append(nxt.strip())
                    i += 1
                else:
                    break

            raw_item = " ".join(item_text_lines)
            m_task = re.match(r"^\[(x|X| )\]\s+(.*)$", raw_item)
            if m_task:
                checked = m_task.group(1).lower() == "x"
                icon = "qi-check-circle-2" if checked else "qi-square"
                cls = "is-checked" if checked else "is-open"
                body = self.format_inline(m_task.group(2))
                self.plain_chunks.append(re.sub(r"<[^>]+>", "", body))
                items.append(
                    f'<li class="docs-task {cls}"><span class="qi {icon}" aria-hidden="true"></span><span>{body}</span></li>'
                )
            else:
                body = self.format_inline(raw_item)
                self.plain_chunks.append(re.sub(r"<[^>]+>", "", body))
                items.append(f"<li>{body}</li>")

        return f"<{tag}>\n" + "\n".join(items) + f"\n</{tag}>", i


def split_table_row(line: str) -> list[str]:
    # Split on unescaped pipes while keeping `a | b` inside backticks intact
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    cells: list[str] = []
    cur: list[str] = []
    in_code = False
    escape = False
    for ch in s:
        if escape:
            cur.append(ch)
            escape = False
            continue
        if ch == "\\":
            escape = True
            cur.append(ch)
            continue
        if ch == "`":
            in_code = not in_code
            cur.append(ch)
            continue
        if ch == "|" and not in_code:
            cells.append("".join(cur).strip())
            cur = []
            continue
        cur.append(ch)
    cells.append("".join(cur).strip())
    return cells


def parse_table_aligns(sep_line: str, ncols: int) -> list[str]:
    parts = split_table_row(sep_line)
    out: list[str] = []
    for idx in range(ncols):
        cell = parts[idx].strip() if idx < len(parts) else ""
        if cell.startswith(":") and cell.endswith(":"):
            out.append("center")
        elif cell.endswith(":"):
            out.append("right")
        else:
            out.append("")
    return out


# Hook inside MarkdownCompiler.format_inline needs clean nested link handler:
def _make_repl_link_fn(compiler: MarkdownCompiler, store_token: Callable[[str], str], code_tokens: list[str]):
    def _fn(m: re.Match[str]) -> str:
        label_raw = m.group(1)
        href_with_title = m.group(2).strip()
        href_raw = href_with_title.split()[0]
        href, is_ext = compiler.resolve_link(href_raw)
        label_html = compiler.format_inline_no_links(label_raw, code_tokens)
        if is_ext:
            return store_token(
                f'<a href="{html.escape(href, quote=True)}" rel="noopener" target="_blank">'
                f'{label_html}<span class="qi qi-arrow-up-right" aria-hidden="true" style="font-size:0.8em;margin-left:0.15rem"></span></a>'
            )
        return store_token(f'<a href="{html.escape(href, quote=True)}">{label_html}</a>')
    return _fn


# Patch format_inline method cleanly onto MarkdownCompiler
def _patched_format_inline(self: MarkdownCompiler, text: str) -> str:
    code_tokens: list[str] = []

    def repl_code(m: re.Match[str]) -> str:
        idx = len(code_tokens)
        code_tokens.append(f"<code>{html.escape(m.group(2))}</code>")
        return f"\x00CODE{idx}\x00"

    s = re.sub(r"(`+)([^`]*?)\1", repl_code, text)
    link_tokens: list[str] = []

    def store_token(rendered: str) -> str:
        idx = len(link_tokens)
        link_tokens.append(rendered)
        return f"\x00LINK{idx}\x00"

    def repl_image(m: re.Match[str]) -> str:
        alt = html.escape(m.group(1))
        src = m.group(2).strip()
        if src.startswith("website/"):
            src = "../" + src[len("website/"):]
        elif not src.startswith(("http://", "https://", "data:")):
            repo_rel = posixpath.normpath(posixpath.join(self.source_dir, src) if self.source_dir else src)
            if repo_rel.startswith("website/"):
                src = "../" + repo_rel[len("website/"):]
            else:
                src = f"https://raw.githubusercontent.com/alikatgh/quenderin/main/{repo_rel}"
        return store_token(f'<img src="{html.escape(src, quote=True)}" alt="{alt}" loading="lazy" />')

    s = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", repl_image, s)
    repl_link = _make_repl_link_fn(self, store_token, code_tokens)
    s = re.sub(r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(([^)]+)\)", repl_link, s)

    def repl_autolink(m: re.Match[str]) -> str:
        url = m.group(1)
        esc = html.escape(url, quote=True)
        return store_token(f'<a href="{esc}" rel="noopener" target="_blank">{html.escape(url)}</a>')

    s = re.sub(r"<(https?://[^>]+)>", repl_autolink, s)

    kbd_tokens: list[str] = []

    def repl_kbd(m: re.Match[str]) -> str:
        idx = len(kbd_tokens)
        kbd_tokens.append(f"<kbd>{html.escape(m.group(1))}</kbd>")
        return f"\x00KBD{idx}\x00"

    s = re.sub(r"<kbd>(.*?)</kbd>", repl_kbd, s, flags=re.I)

    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"__(.+?)__", r"<strong>\1</strong>", s)
    s = re.sub(r"~~(.+?)~~", r"<del>\1</del>", s)
    s = re.sub(r"(?<![A-Za-z0-9])\*([^\s*](?:.*?[^\s*])?)\*(?![A-Za-z0-9])", r"<em>\1</em>", s)
    s = re.sub(r"(?<![A-Za-z0-9/])_([^\s_](?:.*?[^\s_])?)_(?![A-Za-z0-9/])", r"<em>\1</em>", s)

    for idx, val in enumerate(kbd_tokens):
        s = s.replace(f"\x00KBD{idx}\x00", val)
    for idx, val in enumerate(link_tokens):
        s = s.replace(f"\x00LINK{idx}\x00", val)
    for idx, val in enumerate(code_tokens):
        s = s.replace(f"\x00CODE{idx}\x00", val)
    return s


MarkdownCompiler.format_inline = _patched_format_inline  # type: ignore[method-assign]


def load_json(rel_path: str) -> dict:
    return json.loads((ROOT / rel_path).read_text(encoding="utf-8"))


def render_extra_section(key: str, used_ids: set[str], headings: list[dict]) -> str:
    if key == "hub_overview":
        cat = load_json("shared/model-catalog.json")
        total_md = sum(len(p.sources) for p in PAGES)
        cards_by_cat: dict[str, list[DocPage]] = {}
        for p in PAGES[1:]:
            cards_by_cat.setdefault(p.category, []).append(p)
        sections: list[str] = [
            '<div class="docs-stat-row">',
            f'<div class="docs-stat-card"><div class="docs-stat-num">{len(PAGES)}</div><div class="docs-stat-label">Structured documentation guides &amp; hub</div></div>',
            f'<div class="docs-stat-card"><div class="docs-stat-num">{total_md}</div><div class="docs-stat-label">Canonical Markdown files compiled</div></div>',
            f'<div class="docs-stat-card"><div class="docs-stat-num">{len(cat["models"])}</div><div class="docs-stat-label">Curated models in shared catalog</div></div>',
            '<div class="docs-stat-card"><div class="docs-stat-num">$0</div><div class="docs-stat-label">Self-hosted MIT / OFL / ISC static docs</div></div>',
            '</div>',
        ]
        for cat_name, items in cards_by_cat.items():
            cid = f"track-{slugify(cat_name)}"
            used_ids.add(cid)
            headings.append({"id": cid, "text": cat_name, "level": 2})
            sections.append(f'<h2 id="{cid}">{html.escape(cat_name)}</h2>')
            sections.append('<div class="docs-card-grid">')
            for item in items:
                sections.append(
                    f'<a class="docs-card" href="{html.escape(page_href(item.slug))}">'
                    f'<div class="docs-card-head"><span class="qi {html.escape(item.icon)}" aria-hidden="true"></span><span>{html.escape(item.title)}</span></div>'
                    f'<div class="docs-card-desc">{html.escape(item.description)}</div>'
                    f'<div class="docs-card-foot">{len(item.sources)} source file{"s" if len(item.sources) != 1 else ""} &rarr;</div>'
                    f'</a>'
                )
            sections.append('</div>')
        return "\n".join(sections)

    if key == "live_models":
        cat = load_json("shared/model-catalog.json")
        img_cat = load_json("shared/image-model-catalog.json")
        speech_cat = load_json("shared/speech-model-catalog.json")
        hid = "live-gguf-catalog"
        used_ids.add(hid)
        headings.append({"id": hid, "text": f"Live Curated GGUF Catalog ({len(cat['models'])} Models)", "level": 2})
        rows = []
        for m in cat["models"]:
            langs = ", ".join(m.get("languages", [])) or "en"
            sha = m.get("sha256", "")[:12] + "…" if m.get("sha256") else "—"
            rows.append(
                f"<tr><td><strong>{html.escape(m['label'])}</strong><br /><code>{html.escape(m['id'])}</code></td>"
                f"<td>{m.get('paramsBillions', '—')}B</td>"
                f"<td><code>{html.escape(str(m.get('quantization', '—')))}</code></td>"
                f"<td>{html.escape(str(m.get('sizeLabel', '—')))}</td>"
                f"<td>{m.get('ramGb', '—')} GB</td>"
                f"<td>{html.escape(langs)}</td>"
                f"<td><code>{html.escape(sha)}</code></td></tr>"
            )
        out = [
            f'<h2 id="{hid}">Live Curated GGUF Catalog ({len(cat["models"])} Models)</h2>',
            '<p>Generated directly from <code>shared/model-catalog.json</code> (catalog version '
            f'<code>{html.escape(str(cat.get("version", "")))}</code>). Every download is verified by SHA-256 before loading.</p>',
            '<div class="docs-table-wrap"><table><thead><tr>'
            '<th>Model</th><th>Params</th><th>Quant</th><th>Download</th><th>Min RAM</th><th>Languages</th><th>SHA-256 Prefix</th>'
            '</tr></thead><tbody>' + "".join(rows) + '</tbody></table></div>',
        ]
        hid2 = "image-diffusion-catalog"
        used_ids.add(hid2)
        headings.append({"id": hid2, "text": f"Local Image Diffusion Catalog ({len(img_cat.get('models', []))} Models)", "level": 2})
        img_rows = []
        for im in img_cat.get("models", []):
            defs = im.get("defaults", {})
            cfg_txt = f", CFG {defs['cfg']}" if defs.get("cfg") is not None else ""
            spec = f"{defs.get('width', '—')}x{defs.get('height', '—')}, {defs.get('steps', '—')} steps{cfg_txt}"
            img_rows.append(
                f"<tr><td><strong>{html.escape(im['label'])}</strong><br /><code>{html.escape(im['id'])}</code></td>"
                f"<td>{html.escape(im.get('publisher', '—'))}</td>"
                f"<td>{html.escape(im.get('transformerParameters', '—'))}</td>"
                f"<td>{html.escape(spec)}</td>"
                f"<td>{html.escape(im.get('license', '—'))}</td></tr>"
            )
        out.extend([
            f'<h2 id="{hid2}">Local Image Diffusion Catalog ({len(img_cat.get("models", []))} Models)</h2>',
            f'<p>Source: <code>shared/image-model-catalog.json</code> — runtime <code>{html.escape(str(img_cat.get("runtime", "")))}</code>, '
            f'status <code>{html.escape(str(img_cat.get("status", "")))}</code> (verified {html.escape(str(img_cat.get("verifiedAt", "")))}).</p>',
            '<div class="docs-table-wrap"><table><thead><tr>'
            '<th>Model</th><th>Publisher</th><th>Transformer</th><th>Default Run</th><th>License</th>'
            '</tr></thead><tbody>' + "".join(img_rows) + '</tbody></table></div>',
        ])
        hid3 = "speech-dictation-catalog"
        used_ids.add(hid3)
        speech_models = speech_cat.get("models", [])
        headings.append({"id": hid3, "text": f"Local Speech & Dictation Catalog ({len(speech_models)} Models + Silero VAD v6.2)", "level": 2})
        sp_rows = []
        for sp in speech_models:
            langs_list = sp.get("languages", [])
            langs = ", ".join(langs_list[:6]) + (f" (+{len(langs_list) - 6})" if len(langs_list) > 6 else "")
            size_txt = f"{sp['bytes'] / 1e6:.0f} MB" if sp.get("bytes") else "System API"
            sha = (sp.get("sha256") or "")[:12] + "…" if sp.get("sha256") else "—"
            rt_wer = " · ".join(x for x in [sp.get("realtime"), f"{sp['wordErrorRate']}% WER" if sp.get("wordErrorRate") is not None else None] if x) or "—"
            sp_rows.append(
                f"<tr><td><strong>{html.escape(sp['label'])}</strong><br /><code>{html.escape(sp['id'])}</code></td>"
                f"<td><code>{html.escape(sp.get('engine', '—'))}</code></td>"
                f"<td>{html.escape(rt_wer)}</td>"
                f"<td>{html.escape(size_txt)}</td>"
                f"<td>{html.escape(langs)}</td>"
                f"<td><code>{html.escape(sha)}</code></td></tr>"
            )
        vad = speech_cat.get("vad", {})
        out.extend([
            f'<h2 id="{hid3}">Local Speech &amp; Dictation Catalog ({len(speech_models)} Models + Silero VAD v6.2)</h2>',
            f'<p>Source: <code>shared/speech-model-catalog.json</code> — runtime <code>{html.escape(str(speech_cat.get("runtime", "")))}</code> '
            f'(paired with Silero VAD v6.2 <code>{html.escape(str(vad.get("localFilename", "")))}</code>, {vad.get("bytes", 0) / 1e6:.2f} MB).</p>',
            '<div class="docs-table-wrap"><table><thead><tr>'
            '<th>Model</th><th>Engine</th><th>Speed / WER</th><th>Size</th><th>Languages</th><th>SHA-256 Prefix</th>'
            '</tr></thead><tbody>' + "".join(sp_rows) + '</tbody></table></div>',
        ])
        return "\n".join(out)

    if key == "experimental_engines":
        exp = load_json("shared/experimental-model-support.json")
        prism = load_json("shared/prism-runtime.json")
        muse = load_json("shared/muse-spark-artifacts.json")
        diff = load_json("shared/diffusion-runtime.json")
        speech = load_json("shared/speech-runtime.json")
        hid = "experimental-provenance-manifests"
        used_ids.add(hid)
        headings.append({"id": hid, "text": "Live Runtime Provenance & Artifact Manifests", "level": 2})
        exp_rows = []
        for item in exp.get("models", []):
            exp_rows.append(
                f"<tr><td><code>{html.escape(item['modelId'])}</code></td>"
                f"<td><code>{html.escape(item.get('status', '—'))}</code></td>"
                f"<td>{'Yes' if item.get('appAvailable') else 'No (source-only)'}</td>"
                f"<td>{html.escape(', '.join(item.get('modalities', [])))}</td>"
                f"<td><code>{html.escape(str(item.get('artifactManifest', '—')))}</code></td></tr>"
            )
        muse_bytes = sum(a.get("downloadBytes", 0) for a in muse.get("artifacts", []))
        return "\n".join([
            f'<h2 id="{hid}">Live Runtime Provenance &amp; Artifact Manifests</h2>',
            '<aside class="docs-callout docs-callout--warning">'
            '<div class="docs-callout-title"><span class="qi qi-alert-triangle" aria-hidden="true"></span>VERIFICATION BOUNDARY</div>'
            '<div class="docs-callout-body"><p>Per <code>shared/experimental-model-support.json</code> '
            f'(reviewed {html.escape(str(exp.get("reviewedAt", "")))}), <code>shared/diffusion-runtime.json</code> '
            f'(ABI v{diff.get("abiVersion", 2)}, <code>inferenceVerified: {str(diff.get("inferenceVerified", False)).lower()}</code>), and '
            f'<code>shared/speech-runtime.json</code> (ABI v{speech.get("abiVersion", 1)}, <code>inferenceVerified: {str(speech.get("inferenceVerified", False)).lower()}</code>), '
            'source integration and hosted fixture compilation are tracked separately from on-device tested inference.</p></div></aside>',
            '<div class="docs-table-wrap"><table><thead><tr>'
            '<th>Model ID</th><th>Status</th><th>In Public Store</th><th>Modalities</th><th>Manifest</th>'
            '</tr></thead><tbody>' + "".join(exp_rows) + '</tbody></table></div>',
            f'<p><strong>Prism runtime pin:</strong> <code>{html.escape(prism.get("repository", ""))}</code> @ <code>{html.escape(prism.get("revision", "")[:12])}</code> '
            f'(default model <code>{html.escape(prism.get("modelId", ""))}</code>, {prism.get("downloadBytes", 0) / 1e9:.2f} GB).</p>',
            f'<p><strong>Muse Spark manifest:</strong> <code>{html.escape(muse.get("modelId", ""))}</code> — {len(muse.get("artifacts", []))} split GGUF shards '
            f'({muse_bytes / 1e9:.2f} GB total) listed in <code>shared/muse-spark-artifacts.json</code>.</p>',
            f'<p><strong>Diffusion runtime pin:</strong> <code>{html.escape(diff.get("repository", ""))}</code> @ <code>{html.escape(diff.get("revision", "")[:12])}</code> '
            f'(ABI v{diff.get("abiVersion", 2)}, supporting {", ".join(html.escape(c) for c in diff.get("capabilities", []))}).</p>',
            f'<p><strong>Speech &amp; Hex runtime pin:</strong> <code>{html.escape(speech.get("repository", ""))}</code> @ <code>{html.escape(speech.get("revision", "")[:12])}</code> '
            f'+ <code>{html.escape(speech.get("hex", {}).get("repository", ""))}</code> @ <code>{html.escape(speech.get("hex", {}).get("revision", "")[:12])}</code> '
            f'(ABI v{speech.get("abiVersion", 1)}, Hex Local API v{html.escape(str(speech.get("hex", {}).get("localApiVersion", "2")))}).</p>',
        ])

    if key == "perf_contract":
        perf = load_json("shared/inference-performance-contract.json")
        hid = "shared-perf-contract"
        used_ids.add(hid)
        headings.append({"id": hid, "text": "Shared Inference Performance Contract", "level": 2})
        fields = ", ".join(f"<code>{html.escape(f)}</code>" for f in perf.get("sampleFields", []))
        return "\n".join([
            f'<h2 id="{hid}">Shared Inference Performance Contract</h2>',
            f'<p>From <code>shared/inference-performance-contract.json</code> (schema v{perf.get("schemaVersion", 1)}):</p>',
            f'<p>Recorded sample fields across platforms: {fields}.</p>',
        ])

    if key == "remote_contracts":
        nc = load_json("shared/native-connections-contract.json")
        ds = load_json("shared/deepseek-provider-contract.json")
        hid = "shared-remote-contracts"
        used_ids.add(hid)
        headings.append({"id": hid, "text": "Shared Connection & Provider Contracts", "level": 2})
        return "\n".join([
            f'<h2 id="{hid}">Shared Connection &amp; Provider Contracts</h2>',
            '<div class="docs-table-wrap"><table><thead><tr><th>Contract</th><th>Schema Version</th><th>Status / Policy</th><th>Details</th></tr></thead><tbody>'
            f'<tr><td><code>native-connections-contract.json</code></td><td>{nc.get("schemaVersion", "—")}</td>'
            f'<td><code>{html.escape(str(nc.get("status", "—")))}</code></td>'
            f'<td>Destinations: {html.escape(", ".join(nc.get("destinations", [])))}</td></tr>'
            f'<tr><td><code>deepseek-provider-contract.json</code></td><td>{ds.get("schemaVersion", "—")}</td>'
            f'<td><code>{html.escape(str(ds.get("catalogPolicy", "—")))}</code></td>'
            f'<td>Models: {html.escape(", ".join(m.get("id", "") for m in ds.get("models", [])))}</td></tr>'
            '</tbody></table></div>',
        ])

    return ""


def render_page_html(
    page: DocPage,
    prev_page: DocPage | None,
    next_page: DocPage | None,
    src_map: dict[str, tuple[str, str]],
) -> tuple[str, dict]:
    used_ids: set[str] = set()
    headings: list[dict[str, str | int]] = []
    plain_chunks: list[str] = []
    body_parts: list[str] = []

    if page.slug == "index":
        # Render docs/README intro then the interactive card hub
        raw_md = (ROOT / page.sources[0]).read_text(encoding="utf-8", errors="replace")
        comp = MarkdownCompiler(page.sources[0], page.slug, src_map, used_ids, fold_h2=False, base_heading_level=2)
        compiled = comp.compile(raw_md)
        if page.extra_section:
            body_parts.append(render_extra_section(page.extra_section, used_ids, headings))
        headings.extend(comp.headings)
        plain_chunks.extend(comp.plain_chunks)
        body_parts.append('<section class="docs-subdoc">')
        body_parts.append(compiled)
        body_parts.append('</section>')
    else:
        for idx, src in enumerate(page.sources):
            raw_md = (ROOT / src).read_text(encoding="utf-8", errors="replace")
            md_to_compile = raw_md
            if len(page.sources) == 1:
                md_lines = raw_md.lstrip("\ufeff").splitlines()
                first_non_empty = next((k for k, line in enumerate(md_lines) if line.strip()), None)
                if first_non_empty is not None and re.match(r"^#\s+.+$", md_lines[first_non_empty]):
                    md_to_compile = "\n".join(md_lines[first_non_empty + 1 :])
            comp = MarkdownCompiler(
                src, page.slug, src_map, used_ids, fold_h2=page.fold_h2, base_heading_level=2 if idx == 0 and len(page.sources) == 1 else 3
            )
            sub_html = comp.compile(md_to_compile)
            src_id = f"src-{slugify(src)}"
            used_ids.add(src_id)
            if len(page.sources) > 1:
                headings.append({"id": src_id, "text": src, "level": 2})
                sub_title = sanitize_repo_text(
                    next((l.lstrip("# ").strip() for l in raw_md.splitlines() if l.startswith("# ")), src)
                )
                inner = (
                    f'<div class="docs-subdoc-meta">'
                    f'<span><span class="qi qi-file-text" aria-hidden="true"></span> <code>{html.escape(src)}</code></span>'
                    f'<a href="{REPO_BLOB_BASE}{html.escape(src, quote=True)}" rel="noopener" target="_blank">View on GitHub <span class="qi qi-arrow-up-right" aria-hidden="true"></span></a>'
                    f'</div>\n{sub_html}'
                )
                if page.fold_subdocs and idx > 0:
                    body_parts.append(
                        f'<details class="docs-fold docs-subdoc" id="{src_id}">'
                        f'<summary><span><strong>{html.escape(sub_title)}</strong> &mdash; <code>{html.escape(src)}</code></span>'
                        f'<span class="qi qi-chevron-down" aria-hidden="true"></span></summary>'
                        f'<div class="docs-fold-body">{inner}</div></details>'
                    )
                else:
                    body_parts.append(
                        f'<section class="docs-subdoc" id="{src_id}">'
                        f'<h2 id="{src_id}-heading">{html.escape(sub_title)}</h2>'
                        f'{inner}</section>'
                    )
            else:
                body_parts.append(sub_html)

            headings.extend(comp.headings)
            plain_chunks.extend(comp.plain_chunks)

        if page.extra_section:
            extra_html = render_extra_section(page.extra_section, used_ids, headings)
            if extra_html:
                body_parts.insert(0, f'<section class="docs-subdoc">{extra_html}</section>')

    word_count = len(" ".join(plain_chunks).split())
    read_mins = max(1, round(word_count / 230))

    # Build sidebar nav HTML
    groups: dict[str, list[DocPage]] = {}
    for p in PAGES:
        groups.setdefault(p.category, []).append(p)
    sidebar_groups: list[str] = []
    for gname, gpages in groups.items():
        items_html = []
        for gp in gpages:
            active_cls = ' class="is-active" aria-current="page"' if gp.slug == page.slug else ""
            items_html.append(
                f'<li><a href="{html.escape(page_href(gp.slug))}"{active_cls}>'
                f'<span class="qi {html.escape(gp.icon)}" aria-hidden="true"></span>'
                f'<span>{html.escape(gp.title)}</span></a></li>'
            )
        sidebar_groups.append(
            f'<div class="docs-nav-group">'
            f'<div class="docs-group-label">{html.escape(gname)}</div>'
            f'<ul class="docs-nav-list">{"".join(items_html)}</ul>'
            f'</div>'
        )
    sidebar_html = "".join(sidebar_groups)

    # Build On-this-page TOC HTML
    toc_items = "".join(
        f'<li><a class="is-depth-{h["level"]}" href="#{html.escape(str(h["id"]))}">{html.escape(str(h["text"]))}</a></li>'
        for h in headings[:45]
    )
    toc_nav_html = (
        f'<ul class="docs-toc-list">{toc_items}</ul>'
        if toc_items
        else '<p style="font-size:0.82rem;color:var(--text-muted)">Top-level overview</p>'
    )

    # Source pills
    source_pills = "".join(
        f'<a class="docs-source-pill" href="{REPO_BLOB_BASE}{html.escape(s, quote=True)}" rel="noopener" target="_blank">'
        f'<span class="qi qi-file-text" aria-hidden="true"></span>{html.escape(s)}</a>'
        for s in page.sources
    )
    sources_drawer = (
        f'<details class="docs-sources">'
        f'<summary><span class="docs-sources-title"><span class="qi qi-folder-open" aria-hidden="true"></span>'
        f'<span>Compiled from {len(page.sources)} canonical source file{"s" if len(page.sources) != 1 else ""}</span></span>'
        f'<span class="qi qi-chevron-down" aria-hidden="true"></span></summary>'
        f'<div class="docs-sources-list">{source_pills}</div>'
        f'</details>'
    )

    # Pager
    prev_html = (
        f'<a class="docs-pager-card" href="{html.escape(page_href(prev_page.slug))}">'
        f'<span class="docs-pager-dir"><span class="qi qi-arrow-left" aria-hidden="true"></span>Previous</span>'
        f'<span class="docs-pager-title">{html.escape(prev_page.title)}</span></a>'
        if prev_page
        else '<div></div>'
    )
    next_html = (
        f'<a class="docs-pager-card docs-pager-card--next" href="{html.escape(page_href(next_page.slug))}">'
        f'<span class="docs-pager-dir">Next<span class="qi qi-arrow-right" aria-hidden="true"></span></span>'
        f'<span class="docs-pager-title">{html.escape(next_page.title)}</span></a>'
        if next_page
        else '<div></div>'
    )

    page_title_full = page.title if page.slug == "index" else f"{page.title} — Quenderin Docs"
    hero_or_header = (
        f'<div class="docs-hero">'
        f'<div class="docs-kicker"><span class="qi {html.escape(page.icon)}" aria-hidden="true"></span>{html.escape(page.kicker)}</div>'
        f'<h1>{html.escape(page.title)}</h1>'
        f'<p class="docs-lead" style="margin-bottom:0">{html.escape(page.description)}</p>'
        f'<div class="docs-hero-actions">'
        f'<a class="btn btn-primary" href="quickstart"><span class="qi qi-rocket" aria-hidden="true"></span>Quickstart</a>'
        f'<a class="btn btn-ghost" href="models-catalog"><span class="qi qi-cpu" aria-hidden="true"></span>Models (28)</a>'
        f'<a class="btn btn-ghost" href="architecture"><span class="qi qi-layers" aria-hidden="true"></span>Architecture</a>'
        f'<a class="btn btn-ghost" href="api-reference"><span class="qi qi-braces" aria-hidden="true"></span>API Reference</a>'
        f'</div></div>'
        if page.slug == "index"
        else (
            f'<div class="docs-breadcrumbs">'
            f'<a href="../">Quenderin</a><span class="qi qi-chevron-right" aria-hidden="true"></span>'
            f'<a href="./">Docs</a><span class="qi qi-chevron-right" aria-hidden="true"></span>'
            f'<span>{html.escape(page.category)}</span></div>'
            f'<div class="docs-kicker"><span class="qi {html.escape(page.icon)}" aria-hidden="true"></span>{html.escape(page.kicker)}</div>'
            f'<h1>{html.escape(page.title)}</h1>'
            f'<p class="docs-lead">{html.escape(page.description)}</p>'
            f'<div class="docs-meta-bar">'
            f'<span class="docs-meta-chip"><span class="qi qi-clock" aria-hidden="true"></span>{read_mins} min read ({word_count:,} words)</span>'
            f'<span class="docs-meta-chip"><span class="qi qi-file-text" aria-hidden="true"></span>{len(page.sources)} source doc{"s" if len(page.sources) != 1 else ""}</span>'
            f'<span class="docs-meta-chip"><span class="qi qi-shield-check" aria-hidden="true"></span>Self-hosted &middot; zero third-party requests</span>'
            f'</div>'
        )
    )

    doc_html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>{html.escape(page_title_full)}</title>
<meta name="description" content="{html.escape(page.description, quote=True)}" />
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)" />
<meta name="theme-color" content="#0F1B1E" media="(prefers-color-scheme: dark)" />
<script src="../theme.js"></script>
<link rel="canonical" href="{html.escape(page_canonical(page.slug), quote=True)}" />
<link rel="icon" href="../favicon.svg" type="image/svg+xml" />
<link rel="icon" href="../favicon-32.png" sizes="32x32" type="image/png" />
<link rel="icon" href="../favicon-16.png" sizes="16x16" type="image/png" />
<link rel="apple-touch-icon" href="../apple-touch-icon.png" />
<link rel="manifest" href="../site.webmanifest" />
<link rel="preload" href="../fonts/chunkfive-regular.woff2" as="font" type="font/woff2" crossorigin />
<link rel="stylesheet" href="../styles.css?v=20261122-polish" />
<link rel="stylesheet" href="../lucide-icons.css?v=20261122-polish" />
<link rel="stylesheet" href="docs.css?v=20261122-polish" />
</head>
<body class="docs-page">
<a class="skip-link" href="#main">Skip to content</a>

<header class="docs-header">
  <div class="docs-header-inner">
    <div class="docs-brand-group">
      <button class="docs-sidebar-toggle" type="button" aria-label="Open documentation menu" aria-expanded="false" aria-controls="docs-sidebar">
        <span class="qi qi-panel-left" aria-hidden="true"></span>
      </button>
      <a class="docs-brand" href="./" aria-label="Quenderin documentation home">
        <span class="brand-mark" aria-hidden="true"></span>
        <span>Quenderin</span>
        <span class="docs-portal-pill"><span class="qi qi-book-open" aria-hidden="true"></span>Docs</span>
      </a>
    </div>

    <div class="docs-header-actions">
      <nav class="docs-top-links" aria-label="Site sections">
        <a href="../"><span class="qi qi-home" aria-hidden="true"></span><span>Home</span></a>
        <a href="../models"><span class="qi qi-cpu" aria-hidden="true"></span><span>Models</span></a>
        <a href="../download"><span class="qi qi-download" aria-hidden="true"></span><span>Download</span></a>
        <a href="../changelog"><span class="qi qi-history" aria-hidden="true"></span><span>Changelog</span></a>
        <a href="https://github.com/alikatgh/quenderin" rel="noopener" target="_blank"><span class="qi qi-code-2" aria-hidden="true"></span><span>GitHub</span></a>
      </nav>
      <button class="docs-search-btn" id="docs-search-trigger" type="button" aria-label="Search documentation">
        <span class="qi qi-search" aria-hidden="true"></span>
        <span class="docs-search-btn-label">Search docs&hellip;</span>
        <kbd class="docs-search-kbd">/</kbd>
      </button>
      <button class="theme-toggle" type="button" aria-label="Toggle dark mode">
        <span class="qi qi-moon icon-moon" aria-hidden="true"></span>
        <span class="qi qi-sun icon-sun" aria-hidden="true"></span>
      </button>
    </div>
  </div>
</header>

<div class="docs-sidebar-backdrop" id="docs-sidebar-backdrop" aria-hidden="true"></div>

<div class="docs-shell">
  <aside class="docs-sidebar" id="docs-sidebar" aria-label="Documentation sections">
    <div class="docs-sidebar-head">
      <strong>Sections</strong>
      <button class="docs-sidebar-close" type="button" aria-label="Close documentation menu">
        <span class="qi qi-x" aria-hidden="true"></span>
      </button>
    </div>
    {sidebar_html}
  </aside>

  <main class="docs-main" id="main">
    <article class="docs-article">
      {hero_or_header}
      {sources_drawer}
      <details class="docs-mobile-toc">
        <summary><span><span class="qi qi-list" aria-hidden="true"></span> On this page</span><span class="qi qi-chevron-down" aria-hidden="true"></span></summary>
        {toc_nav_html}
      </details>
      <div class="docs-prose">
        {"".join(body_parts)}
      </div>
      <nav class="docs-pager" aria-label="Documentation pagination">
        {prev_html}
        {next_html}
      </nav>
    </article>
  </main>

  <aside class="docs-toc" aria-label="On this page">
    <div class="docs-toc-title"><span class="qi qi-list" aria-hidden="true"></span>On this page</div>
    {toc_nav_html}
  </aside>
</div>

<footer class="docs-footer">
  <div class="docs-footer-inner">
    <span>Quenderin Documentation &middot; MIT Licensed &middot; Typography: DINish, ChunkFive, Lucide (self-hosted, free)</span>
    <nav class="docs-footer-links" aria-label="Footer">
      <a href="../">Home</a>
      <a href="../tell-me-more">Overview</a>
      <a href="../download">Download</a>
      <a href="../privacy">Privacy</a>
      <a href="https://github.com/alikatgh/quenderin" rel="noopener" target="_blank">GitHub</a>
    </nav>
  </div>
</footer>

<dialog class="docs-search-dialog" id="docs-search-dialog" aria-labelledby="docs-search-label">
  <div class="docs-search-wrap">
    <div class="docs-search-input-row">
      <span class="qi qi-search" aria-hidden="true"></span>
      <input class="docs-search-input" id="docs-search-input" type="search" autocomplete="off" placeholder="Search documentation, API endpoints, models, errors..." aria-label="Search documentation" />
      <span id="docs-search-label" style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)">Search documentation</span>
      <button class="docs-search-close" id="docs-search-close" type="button">Esc</button>
    </div>
    <div class="docs-search-results" id="docs-search-results"></div>
  </div>
</dialog>

<script src="search-index.js?v=20261122-polish" defer></script>
<script src="docs.js?v=20261122-polish" defer></script>
</body>
</html>
"""

    search_entry = {
        "slug": page.slug,
        "href": page_href(page.slug),
        "title": page.title,
        "category": page.category,
        "icon": page.icon,
        "summary": page.description,
        "sources": list(page.sources),
        "headings": headings[:40],
        "body": " ".join(plain_chunks)[:24000],
    }
    return doc_html, search_entry


def validate_internal_links(generated_files: dict[pathlib.Path, str]) -> list[str]:
    """Ensure every internal docs link resolves to a generated docs page, website/*.html, or asset."""
    ids_by_path: dict[pathlib.Path, set[str]] = {}
    for p, content in generated_files.items():
        if p.suffix == ".html":
            ids_by_path[p] = set(re.findall(r'\bid="([^"]+)"', content))

    errors: list[str] = []
    for p, content in generated_files.items():
        if p.suffix != ".html":
            continue
        for raw_href in re.findall(r'<a[^>]+href="([^"]+)"', content):
            href = html.unescape(raw_href)
            if href.startswith(("http://", "https://", "mailto:", "tel:")):
                continue
            target_part, _, frag = href.partition("#")
            if not target_part:
                if frag and frag not in ids_by_path[p]:
                    errors.append(f"{p.name}: missing local anchor #{frag}")
                continue
            if target_part in ("./", "."):
                target_file = DOCS_OUT / "index.html"
            elif target_part.startswith("../"):
                rel = target_part[3:].rstrip("/")
                candidates = [
                    ROOT / "website" / "index.html" if rel == "" else ROOT / "website" / f"{rel}.html",
                    ROOT / "website" / rel / "index.html",
                    ROOT / "website" / rel,
                ]
                if not any(c.exists() for c in candidates):
                    errors.append(f"{p.name}: broken parent site link {href}")
                continue
            else:
                clean = target_part.rstrip("/")
                target_file = DOCS_OUT / f"{clean}.html"

            if target_file not in ids_by_path:
                errors.append(f"{p.name}: missing target doc {href} ({target_file})")
            elif frag and frag not in ids_by_path[target_file]:
                errors.append(f"{p.name}: missing anchor #{frag} in {target_file.name}")
    return errors


def build_all() -> dict[pathlib.Path, str]:
    src_map, _ = build_source_map()
    missing = [src for p in PAGES for src in p.sources if not (ROOT / src).exists()]
    if missing:
        raise FileNotFoundError(f"Missing canonical docs: {missing}")

    generated: dict[pathlib.Path, str] = {}
    search_index: list[dict] = []
    for i, page in enumerate(PAGES):
        prev_p = PAGES[i - 1] if i > 0 else None
        next_p = PAGES[i + 1] if i + 1 < len(PAGES) else None
        html_out, search_entry = render_page_html(page, prev_p, next_p, src_map)
        generated[DOCS_OUT / f"{page.slug}.html"] = html_out
        search_index.append(search_entry)

    idx_json = json.dumps(search_index, ensure_ascii=False, separators=(",", ":"))
    generated[DOCS_OUT / "search-index.json"] = idx_json + "\n"
    generated[DOCS_OUT / "search-index.js"] = f"window.QUENDERIN_DOCS_INDEX={idx_json};\n"
    return generated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify website/docs matches generated output")
    args = parser.parse_args(argv)

    generated = build_all()
    link_errors = validate_internal_links(generated)
    if link_errors:
        print(f"ERROR: {len(link_errors)} broken internal doc link(s):", file=sys.stderr)
        for err in link_errors[:30]:
            print(f"  {err}", file=sys.stderr)
        return 1

    expected_names = {p.name for p in generated}
    if args.check:
        stale = []
        for path, content in generated.items():
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(path.relative_to(ROOT).as_posix())
        extra_html = [
            p.relative_to(ROOT).as_posix()
            for p in DOCS_OUT.glob("*.html")
            if p.name not in expected_names
        ]
        if stale or extra_html:
            print(f"STALE website/docs files: {stale}; extra HTML: {extra_html}", file=sys.stderr)
            return 1
        print(f"OK: {len(PAGES)} docs pages and search index match ({sum(len(p.sources) for p in PAGES)} sources, 0 broken links)")
        return 0

    DOCS_OUT.mkdir(parents=True, exist_ok=True)
    for old in DOCS_OUT.glob("*.html"):
        if old.name not in expected_names:
            old.unlink()
    for path, content in generated.items():
        path.write_text(content, encoding="utf-8")
    print(f"Generated {len(PAGES)} docs pages + search index ({sum(len(p.sources) for p in PAGES)} sources, 0 broken links)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
