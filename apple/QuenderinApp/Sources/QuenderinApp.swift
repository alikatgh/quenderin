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
    @StateObject private var agent: AgentSession

    init() {
        let engine: InferenceEngine = MockInferenceEngine()       // ← swap to LlamaEngine()
        let downloader: ModelDownloader = MockModelDownloader()    // ← swap to URLSessionModelDownloader()
        _onboarding = StateObject(wrappedValue: OnboardingModel(downloader: downloader, engine: engine))
        _chat = StateObject(wrappedValue: ChatModel(engine: engine))
        // M4: the agent shares the SAME engine (one model, loaded once in onboarding).
        _agent = StateObject(wrappedValue: AgentSession(engine: engine, tools: [CalculatorTool(), EchoTool()]))
    }

    var body: some Scene {
        WindowGroup {
            RootView(onboarding: onboarding, chat: chat, agent: agent)
        }
    }
}
