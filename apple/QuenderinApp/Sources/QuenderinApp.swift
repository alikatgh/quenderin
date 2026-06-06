import SwiftUI
import QuenderinKit

/// The Quenderin iOS app entry point.
///
/// Today it runs on the **mock** engine + downloader so the whole flow
/// (onboarding → chat) is clickable without llama.cpp or a model file. To go
/// real, change the two lines in `init()`:
///   - `MockInferenceEngine()`   → `LlamaEngine()`            (once llama.cpp is linked)
///   - `MockModelDownloader()`   → `URLSessionModelDownloader()`
/// Nothing else changes — both sit behind protocol seams, and onboarding + chat
/// share ONE engine instance (load in onboarding, generate in chat).
@main
struct QuenderinApp: App {
    @StateObject private var onboarding: OnboardingModel
    @StateObject private var chat: ChatModel

    init() {
        let engine: InferenceEngine = MockInferenceEngine()       // ← swap to LlamaEngine()
        let downloader: ModelDownloader = MockModelDownloader()    // ← swap to URLSessionModelDownloader()
        _onboarding = StateObject(wrappedValue: OnboardingModel(downloader: downloader, engine: engine))
        _chat = StateObject(wrappedValue: ChatModel(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            RootView(onboarding: onboarding, chat: chat)
        }
    }
}
