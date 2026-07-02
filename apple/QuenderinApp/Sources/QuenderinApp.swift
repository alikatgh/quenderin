import SwiftUI
import QuenderinKit

/// The Quenderin app entry point — shared by the iOS target and the macOS target
/// (QuenderinMac), which compile this same file per platform.
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
        // Pass the device's app-memory budget (jetsam headroom) so the engine sizes n_ctx from it +
        // the chosen model's footprint at load — no KV-cache OOM on memory-tight phones (M1).
        let engine: InferenceEngine = DefaultInferenceEngine.make(deviceBudgetGB: HardwareProbe.appMemoryBudgetGB()) // real LlamaEngine when llama.cpp is linked, else mock
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
                #if os(macOS)
                // The same SwiftUI flow runs on the Mac (QuenderinMac target); give the window a
                // chat-app footprint instead of the tiny fit-to-content default.
                .frame(minWidth: 720, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 700)
        .commands {
            // ⌘N = new chat, in the File menu where Mac users expect it (replaces "New Window" —
            // Quenderin is a single-window chat app).
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { conversations.startNew() }
                    .keyboardShortcut("n")
            }
        }
        #endif

        #if os(macOS)
        // The standard ⌘, Settings window. Model management only makes sense once onboarding
        // finished (the engine + catalog state live behind .ready).
        Settings {
            Group {
                if case .ready(let model) = onboarding.phase {
                    SettingsView(coordinator: conversations, model: model, onSelectModel: { picked in
                        onboarding.beginInstall(picked)
                    })
                } else {
                    Text("Finish setting up Quenderin in the main window first.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
            .frame(minWidth: 540, minHeight: 480)
        }
        #endif
    }
}
