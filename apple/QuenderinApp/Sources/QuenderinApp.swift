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
#if os(macOS)
/// Quit must NOT run C++ static destructors: after any inference, llama.cpp's Metal backend
/// keeps a residency-set worker alive for the process lifetime, and its GLOBAL teardown in
/// `__cxa_finalize` hits `ggml_abort` → SIGABRT — "Quenderin quit unexpectedly" on every ⌘Q
/// (crash reports 0.2.0(5), 2026-07-17; 11 in one day, byte-identical llama offsets). Every
/// piece of user state is persisted continuously (conversations per turn, agent ledger per
/// action, settings via UserDefaults), so after a defaults flush a hard `_exit(0)` — which
/// skips atexit/finalizers entirely — loses nothing and is the established workaround for
/// ggml's Metal teardown assert. Never replace with `exit(0)`: that RUNS the finalizers.
final class QuenderinMacAppDelegate: NSObject, NSApplicationDelegate {
    /// Quenderin is a single-window chat app: closing the main window must QUIT, not leave a
    /// windowless ghost process with no way back (App Review 4.0.0 Design, 0.2.0(9), 2026-07-19 —
    /// "when the user closes the main window there is no menu item to re-open it"). Apple's
    /// sanctioned single-window remedy is exactly this: save state and quit on last-window-close.
    /// Nothing is lost — every piece of user state is persisted continuously (conversations per
    /// turn, agent ledger per action, settings via UserDefaults), and relaunch restores the active
    /// model straight to `.ready` and the most-recent conversation. The Settings (⌘,) window is a
    /// separate window, so this only fires once the LAST window closes. Termination still flows
    /// through `applicationShouldTerminate` below → the `_exit(0)` that dodges ggml's Metal-teardown
    /// SIGABRT.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UserDefaults.standard.synchronize()
        _exit(0)
    }
}
#endif

@main
struct QuenderinApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(QuenderinMacAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var onboarding: OnboardingModel
    @StateObject private var conversations: ConversationCoordinator
    @StateObject private var agent: AgentSession

    init() {
        // Pass the device's app-memory budget (jetsam headroom) so the engine sizes n_ctx from it +
        // the chosen model's footprint at load — no KV-cache OOM on memory-tight phones (M1).
        let engine: InferenceEngine = DefaultInferenceEngine.make(deviceBudgetGB: HardwareProbe.appMemoryBudgetGB()) // real LlamaEngine when llama.cpp is linked, else mock
        let downloader: ModelDownloader = URLSessionModelDownloader() // real GGUF download (parity with Android's WorkManagerModelDownloader)
        // Q-578: onboarding's download gate honors the user's cellular opt-in (Settings → Downloaded
        // models). Off by default → Wi-Fi-only; the live network status comes from the model's own monitor.
        _onboarding = StateObject(wrappedValue: OnboardingModel(downloader: downloader, engine: engine, downloadPolicy: { AppSettings.shared.downloadPolicy }))
        // Chat + on-device conversation history: the coordinator owns the ChatModel, restores the
        // most recent conversation on launch, and persists each turn to Application Support.
        let chat = ChatModel(engine: engine)
        _conversations = StateObject(wrappedValue: ConversationCoordinator(chat: chat, persistence: FileConversationPersistence()))
        // M4: the agent shares the SAME engine (one model, loaded once in onboarding).
        // Tools come from the ONE toolkit the Settings pane also reads; capabilities execute
        // through the runner — consent from UserDefaults (the pane's toggles), every action
        // ledgered to the on-disk flight recorder (AGENT_AUTONOMY_PLAN Milestone 0).
        _agent = StateObject(wrappedValue: AgentSession(
            engine: engine,
            tools: AgentToolkit.standard(),
            consent: UserDefaultsConsentStore(),   // the Settings pane's toggles
            ledger: FileAuditLedger()              // the on-disk flight recorder
        ))
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
            .frame(minWidth: 680, minHeight: 440)
        }
        #endif
    }
}
