# Quenderin iOS app target

The thin SwiftUI app that hosts `QuenderinKit`. All the logic lives in the
package; this is just the `@main` entry point + Xcode project.

## Build & run

```bash
brew install xcodegen        # one-time
cd apple/QuenderinApp
xcodegen                     # generates Quenderin.xcodeproj from project.yml
open Quenderin.xcodeproj     # then Run on an iOS Simulator
```

On launch you'll see the onboarding flow (probe → recommend → download → ready),
then the chat screen — all on the **mock** engine, so it works with no model
file and no llama.cpp.

## Going real

In `Sources/QuenderinApp.swift`, swap the two lines in `init()`:

| Mock (today) | Real |
|---|---|
| `MockInferenceEngine()` | `LlamaEngine()` — after linking llama.cpp (see `../QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift`) |
| `MockModelDownloader()` | `URLSessionModelDownloader()` |

Nothing else changes — both are behind protocol seams, and onboarding + chat
share one engine instance.

> The `.xcodeproj` is generated, not committed (see `.gitignore`). Run `xcodegen`
> to (re)create it.
