# macOS 0.2.0 (11) — September 20, 2026

Based on main 5409aa8. Signed archive uploaded successfully to App Store Connect. Native download, real chat, last-window-close, and relaunch checks passed; resubmission is in progress.

The July 19 rejection reported a failed model download (2.1a) and inability to reopen the single main window (4). The latest source corrects the recommended Gemma download URL and exits after saving when the last window closes.

This release pins official llama.cpp f072b103714dfa1eee531f80b24512faf38e3dd2, links its real universal macOS Metal framework, and adapts repetition penalties to the new vocabulary-size argument. The Mac deployment target is 13.3 to match that framework. Release builds reject a missing framework. The Apple framework builder fetches the pinned revision deterministically.

Validation completed:
- All 13 catalog URLs responded successfully; sampling/catalog parity checks passed.
- Final Swift suite: 536 tests, 3 optional skips, zero failures; the four real Llama inference tests ran in this suite.
- Dedicated Gemma regression suite: three tests passed, including real 7.12 GB Gemma inference. The model downloaded inside the signed app and passed its SHA-256 check.
- Signed build 11 generated a clean Gemma response, exited after closing its last window, and restored the conversation and active model on relaunch. Qwen3 4B inference was also verified.
- Final Release archive and App Store upload succeeded.
- Four refreshed 2880x1800 screenshots rendered from native SwiftUI views with isolated sample conversations and a real unit-conversion tool run. Apple processed all four with matching checksums.

Reproduce store captures with QUENDERIN_STORE_ASSETS=/absolute/output/path swift test --filter WebsiteAssetRenderTests/testRenderMacStoreAssets in apple/QuenderinKit. The scripted planner is confined to screenshot fixtures; distribution uses the real engine.

GitHub CI: Apple package tests and iOS simulator app build passed, along with catalog parity, Node 20/22 tests, Android core and JNI checks. Android APK CI failed before compilation because the existing SDK setup requests the unavailable `tools` package; this Apple release does not modify Android code or that workflow.

Native QA exposed an additional Gemma 4 issue: the legacy C chat-template API does not interpret its new Jinja conversation format, causing a flat-transcript fallback and visible channel markers. Gemma4ChatPrompt now supplies native role delimiters and a closed thinking channel, matching the text-only, thinking-disabled path in the pinned upstream template. Other model templates retain their existing path. Build 10 was uploaded for preparation; build 11 supersedes it with this fix.
