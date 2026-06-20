import SwiftUI
import QuenderinKit

/// The Quenderin iOS app entry point.
///
/// Both seams are now wired to their real implementations:
///   - engine: `DefaultInferenceEngine.make()` → real `LlamaEngine` when this build
///     links llama.cpp (`canImport(llama)` — `QUENDERIN_LLAMA_DIR` or the xcframework),
///     else the mock so the whole flow (onboarding → chat) stays clickable with no model.
///   - downloader: `URLSessionModelDownloader` → real streamed GGUF download.
/// Both sit behind protocol seams, and onboarding + chat share ONE engine instance
/// (load in onboarding, generate in chat).
@main
struct QuenderinApp: App {
    @StateObject private var onboarding: OnboardingModel
    @StateObject private var conversations: ConversationCoordinator
    @StateObject private var agent: AgentSession

    init() {
        let engine: InferenceEngine = DefaultInferenceEngine.make() // real LlamaEngine when llama.cpp is linked, else mock
        let downloader: ModelDownloader = URLSessionModelDownloader() // real GGUF download (parity with Android's WorkManagerModelDownloader)
        _onboarding = StateObject(wrappedValue: OnboardingModel(downloader: downloader, engine: engine))
        // Chat + on-device conversation history: the coordinator owns the ChatModel, restores the
        // most recent conversation on launch, and persists each turn to Application Support.
        let chat = ChatModel(engine: engine)
        _conversations = StateObject(wrappedValue: ConversationCoordinator(chat: chat, persistence: FileConversationPersistence()))
        // M4: the agent shares the SAME engine (one model, loaded once in onboarding).
        _agent = StateObject(wrappedValue: AgentSession(engine: engine, tools: [CalculatorTool(), UnitConverterTool(), DateCalcTool(), EchoTool()]))
    }

    var body: some Scene {
        WindowGroup {
            RootView(onboarding: onboarding, conversations: conversations, agent: agent)
        }
    }
}
