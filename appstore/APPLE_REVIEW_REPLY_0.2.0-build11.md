Quenderin macOS 0.2.0 (11) addresses the July 19 review of build 9.

Guideline 2.1(a): The recommended Gemma 4 12B download URL was corrected. All 13 catalog download endpoints were checked on September 20. This build includes the real llama.cpp inference engine with native Metal support, pinned to revision f072b103714dfa1eee531f80b24512faf38e3dd2. It does not use a mock inference engine.

Guideline 4: This is a single-window Mac app. Closing the main window saves local state and exits the app; opening Quenderin again restores the workspace. This implements the save-and-exit behavior suggested in the review message.

No account or login is required. On first launch, continue to the model picker and download a model. Downloads require an internet connection and sufficient disk space; models range from approximately 0.58 GB to 13.2 GB. The recommended Gemma model is approximately 7.1 GB. For a shorter initial download, choose Llama 3.2 1B Ultra-Light. Once installed, chat inference runs locally and works offline. Optional tools that access device capabilities require user permission.

Test coverage: 536 Swift tests with no failures (3 optional skips), including 4 passing real-model inference tests with a checksum-verified Llama model. Native Qwen3 4B chat was also verified in the signed Mac app. Four updated native Mac screenshots accompany this build. Requires macOS 13.3 or later.

Final native verification on September 20: the full 7.12 GB recommended Gemma 4 model downloaded through the signed app and passed integrity verification, loaded, and generated a reply. Build 11 also corrects Gemma 4 conversation formatting so internal channel markers do not appear in replies. A dedicated three-test Gemma regression run passed, including real inference. The final signed app produced a clean response, exited when its main window closed, and restored its model and conversation on relaunch.
