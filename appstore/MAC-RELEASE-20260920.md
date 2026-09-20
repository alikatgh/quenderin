# macOS 0.2.0 (10) — September 20, 2026

Based on main 5409aa8. Signed archive uploaded successfully to App Store Connect. Submission pending completion of the final native download/relaunch checks.

The July 19 rejection reported a failed model download (2.1a) and inability to reopen the single main window (4). The latest source corrects the recommended Gemma download URL and exits after saving when the last window closes.

This release pins official llama.cpp f072b103714dfa1eee531f80b24512faf38e3dd2, links its real universal macOS Metal framework, and adapts repetition penalties to the new vocabulary-size argument. The Mac deployment target is 13.3 to match that framework. Release builds reject a missing framework. The Apple framework builder fetches the pinned revision deterministically.

Validation completed:
- All 13 catalog URLs responded successfully; sampling/catalog parity checks passed.
- Swift suite: 532 tests, 5 optional skips, zero failures.
- Four real-model inference tests passed with the SHA-256-verified Llama 3.2 1B Q2_K model, including KV reuse and context shifts.
- Signed native app generated a local Qwen3 4B response.
- Final Release archive and App Store upload succeeded.
- Four refreshed 2880x1800 screenshots rendered from native SwiftUI views with isolated sample conversations and a real unit-conversion tool run. Apple processed all four with matching checksums.

Reproduce store captures with QUENDERIN_STORE_ASSETS=/absolute/output/path swift test --filter WebsiteAssetRenderTests/testRenderMacStoreAssets in apple/QuenderinKit. The scripted planner is confined to screenshot fixtures; distribution uses the real engine.
