#!/usr/bin/env python3
"""Apple and Android share the on-device job sentences and the first-open card.

Desktop Electron is not the Mac product, so it is not a third copy of this job.
The sentences are the ones a person reads. Host checks do not claim tested inference.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPLE = ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "OnDeviceJob.swift"
ANDROID = ROOT / "android" / "quenderin-core" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "core" / "OnDeviceJob.kt"
SURFACES = {
    "iOS and macOS chat": ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "ChatView.swift",
    "iOS and macOS settings": ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "SettingsView.swift",
    "Android chat": ROOT / "android" / "app" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "app" / "ui" / "ChatScreen.kt",
    "Android settings": ROOT / "android" / "app" / "src" / "main" / "kotlin" / "ai" / "quenderin" / "app" / "ui" / "SettingsScreen.kt",
}
PHRASES = [
    "Each job can use a different model. Replies and tool results are checked on this device before they are shown. No account.",
    "Shape and word check",
    "Not loaded",
    "This checkup did not start a chat and did not run a model.",
    "This scores tool use on saved questions. It does not score the model.",
    "This is not tested inference.",
    "No local tool servers. Add one on this device if you want.",
    "Only a tool server on this device is allowed.",
    "The local tool server did not answer.",
    "Photos and speech stay closed until you open them. This checkup did not open them.",
    "A command is available on Mac. This device uses a local address.",
    "Selected. This checkup did not load it.",
    "This checkup did not run a tool.",
    "This chat",
    "Run checkup",
    "Run the saved questions",
    "Look up tools",
    "Photos and speech",
]


def main() -> int:
    missing = []
    apple = APPLE.read_text(encoding="utf-8")
    android = ANDROID.read_text(encoding="utf-8")
    for phrase in PHRASES:
        if phrase not in apple:
            missing.append(f"Apple missing: {phrase}")
        if phrase not in android:
            missing.append(f"Android missing: {phrase}")
    for name, path in SURFACES.items():
        text = path.read_text(encoding="utf-8")
        needle = "OnDeviceJobCard" if path.suffix == ".swift" else "OnDeviceCard"
        if needle not in text:
            missing.append(f"{name} does not show {needle}")
    mac = (ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "MacRootView.swift").read_text(encoding="utf-8")
    if "ChatView(" not in mac:
        missing.append("macOS detail does not open ChatView")
    if "scoreLive" not in (ROOT / "apple" / "QuenderinKit" / "Sources" / "QuenderinKit" / "OnDeviceJobView.swift").read_text(encoding="utf-8"):
        missing.append("Apple practice button does not call scoreLive")
    if missing:
        print("\n".join(missing))
        return 1
    print(f"on-device job copy matches ({len(PHRASES)} sentences, {len(SURFACES)} surfaces)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
