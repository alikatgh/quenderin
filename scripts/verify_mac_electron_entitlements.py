#!/usr/bin/env python3
"""Verify macOS Electron Hardened Runtime audio-input entitlements and signed bundles."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
BUILDER_CONFIG = ROOT / "electron-builder.yaml"
REQUIRED_ENTITLEMENTS = (
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.device.audio-input",
)


def parse_plist_bytes(raw: bytes, label: str) -> dict:
    try:
        parsed = plistlib.loads(raw)
    except Exception as error:
        raise ValueError(f"Invalid plist for {label}: {error}") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"Expected dictionary plist for {label}")
    return parsed


def verify_entitlements_dict(entitlements: dict, label: str) -> None:
    missing = [key for key in REQUIRED_ENTITLEMENTS if entitlements.get(key) is not True]
    if missing:
        raise ValueError(f"{label} missing required entitlements: {', '.join(missing)}")


def verify_config(root: Path = ROOT) -> dict:
    config_text = (root / "electron-builder.yaml").read_text(encoding="utf-8")
    mac_match = re.search(r"^mac:\s*\n((?:[ \t]+[^\n]*\n|\n)*)", config_text, re.MULTILINE)
    if not mac_match:
        raise ValueError("electron-builder.yaml is missing the mac section")
    mac_section = mac_match.group(1)
    if not re.search(r"^\s+hardenedRuntime:\s*true\s*$", mac_section, re.MULTILINE):
        raise ValueError("electron-builder.yaml mac.hardenedRuntime must be true")
    if not re.search(r"^\s+NSMicrophoneUsageDescription:\s*\S+", mac_section, re.MULTILINE):
        raise ValueError("electron-builder.yaml mac.extendInfo.NSMicrophoneUsageDescription is required")
    ent_match = re.search(r"^\s+entitlements:\s*(\S+)\s*$", mac_section, re.MULTILINE)
    inherit_match = re.search(r"^\s+entitlementsInherit:\s*(\S+)\s*$", mac_section, re.MULTILINE)
    if not ent_match or not inherit_match:
        raise ValueError("electron-builder.yaml must configure both mac.entitlements and mac.entitlementsInherit")
    ent_path = root / ent_match.group(1).strip("'\"")
    inherit_path = root / inherit_match.group(1).strip("'\"")
    for label, path in (("mac.entitlements", ent_path), ("mac.entitlementsInherit", inherit_path)):
        if not path.is_file():
            raise ValueError(f"{label} file not found: {path}")
        verify_entitlements_dict(parse_plist_bytes(path.read_bytes(), label), label)
    return {
        "entitlements": str(ent_path.relative_to(root)),
        "entitlementsInherit": str(inherit_path.relative_to(root)),
        "requiredKeys": list(REQUIRED_ENTITLEMENTS),
    }


def inspect_codesign(target: Path, runner=subprocess.run) -> tuple[bool, dict | None]:
    info = runner(["codesign", "-dv", str(target)], capture_output=True, text=True, check=False)
    combined = (info.stdout or "") + "\n" + (info.stderr or "")
    hardened = bool(re.search(r"flags=0x[0-9a-f]+\([^)]*\bruntime\b", combined, re.IGNORECASE))
    ent = runner(["codesign", "-d", "--entitlements", ":-", "--xml", str(target)], capture_output=True, check=False)
    if ent.returncode != 0 or not ent.stdout:
        return hardened, None
    xml_start = ent.stdout.find(b"<?xml")
    if xml_start < 0:
        return hardened, None
    return hardened, parse_plist_bytes(ent.stdout[xml_start:], str(target))


def verify_codesign_strict(app_path: Path, runner=subprocess.run) -> None:
    check = runner(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if check.returncode != 0:
        detail = ((check.stderr or "") + "\n" + (check.stdout or "")).strip()
        raise ValueError(f"codesign --verify --deep --strict failed for {app_path.name}: {detail or check.returncode}")


def verify_app(app_path: Path, *, require_signed: bool = False, runner=subprocess.run) -> dict:
    app_path = app_path.resolve(strict=True)
    info_plist = app_path / "Contents" / "Info.plist"
    if not info_plist.is_file():
        raise ValueError(f"Missing Info.plist in {app_path}")
    info = parse_plist_bytes(info_plist.read_bytes(), "Info.plist")
    usage = info.get("NSMicrophoneUsageDescription")
    if not isinstance(usage, str) or not usage.strip():
        raise ValueError("Packaged Info.plist is missing NSMicrophoneUsageDescription")

    frameworks_dir = app_path / "Contents" / "Frameworks"
    helpers = sorted(p for p in frameworks_dir.glob("*Helper*.app") if p.is_dir()) if frameworks_dir.is_dir() else []
    if not helpers:
        raise ValueError(f"{app_path.name} is missing Electron Helper bundles in Contents/Frameworks")
    if not any("Renderer" in helper.name for helper in helpers):
        raise ValueError(f"{app_path.name} is missing the Electron Renderer helper bundle")

    if require_signed:
        verify_codesign_strict(app_path, runner=runner)

    targets = [app_path, *helpers]
    checked = []
    for target in targets:
        hardened, entitlements = inspect_codesign(target, runner=runner)
        if require_signed and not hardened:
            raise ValueError(f"{target.name} is not signed with Hardened Runtime")
        if hardened or require_signed:
            if entitlements is None:
                raise ValueError(f"{target.name} is signed with Hardened Runtime but has no embedded entitlements")
            verify_entitlements_dict(entitlements, target.name)
        checked.append({"bundle": target.name, "hardenedRuntime": hardened, "entitlementsVerified": bool(hardened and entitlements)})
    return {
        "app": app_path.name,
        "microphoneUsageDescription": True,
        "rendererHelperVerified": True,
        "codeSignatureVerified": bool(require_signed),
        "bundles": checked,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Optional packaged macOS .app bundle to inspect")
    parser.add_argument("--require-signed", action="store_true", help="Fail unless the app and helpers are signed with Hardened Runtime")
    args = parser.parse_args()
    try:
        result = {"config": verify_config()}
        if args.app:
            result["package"] = verify_app(args.app, require_signed=args.require_signed)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"macOS Electron entitlement verification failed: {error}\n")


if __name__ == "__main__":
    main()
