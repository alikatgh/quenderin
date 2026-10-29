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
private enum QuenderinMacWindow {
    enum Identity: String, Codable, Hashable { case main }
    static let id = "main"
    static let showMainWindow = Notification.Name("QuenderinShowMainWindow")
}

/// Quit must NOT run C++ static destructors: after any inference, llama.cpp's Metal backend
/// keeps a residency-set worker alive for the process lifetime, and its GLOBAL teardown in
/// `__cxa_finalize` hits `ggml_abort` → SIGABRT — "Quenderin quit unexpectedly" on every ⌘Q
/// (crash reports 0.2.0(5), 2026-07-17; 11 in one day, byte-identical llama offsets). Every
/// piece of user state is persisted continuously (conversations per turn, agent ledger per
/// action, settings via UserDefaults), so after a defaults flush a hard `_exit(0)` — which
/// skips atexit/finalizers entirely — loses nothing and is the established workaround for
/// ggml's Metal teardown assert. Never replace with `exit(0)`: that RUNS the finalizers.
@MainActor
final class QuenderinMacAppDelegate: NSObject, NSApplicationDelegate {
    var showMainWindow: @MainActor () -> Void = {
        NotificationCenter.default.post(name: QuenderinMacWindow.showMainWindow, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Settings may be the visible window, so always restore/focus the main scene.
        showMainWindow()
        return false
    }

    /// Preserve last-window-close quitting instead of leaving a
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

private struct QuenderinMacWindowRecovery: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: QuenderinMacWindow.showMainWindow)) { _ in
            openWindow(id: QuenderinMacWindow.id, value: QuenderinMacWindow.Identity.main)
        }
    }
}

private struct QuenderinMacWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let conversations: ConversationCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                conversations.startNew()
                openWindow(id: QuenderinMacWindow.id, value: QuenderinMacWindow.Identity.main)
            }
            .keyboardShortcut("n")
        }
        CommandGroup(before: .windowList) {
            Button("Show Main Window") {
                openWindow(id: QuenderinMacWindow.id, value: QuenderinMacWindow.Identity.main)
            }
            .keyboardShortcut("0")
        }
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
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // Pass the device's app-memory budget (jetsam headroom) so the engine sizes n_ctx from it +
        // the chosen model's footprint at load — no KV-cache OOM on memory-tight phones (M1).
        // QA harness (DEBUG builds only): `QUENDERIN_MOCK_UI=1` in the environment swaps BOTH seams for
        // the same mocks the tests inject, so every screen — onboarding → chat → history → settings →
        // agent — is walkable on a simulator with no multi-GB download and no llama.cpp. The mock
        // downloader writes an empty placeholder; the mock engine answers with DemoMockReplies.
        //   scripts/ios_sim_run.sh --mock            (build + install + launch with the flag)
        //   SIMCTL_CHILD_QUENDERIN_MOCK_UI=1 xcrun simctl launch <udid> ai.quenderin.Quenderin
        // Not compiled into Release: the store build always runs the real engine + downloader.
        #if DEBUG
        let mockUI = ProcessInfo.processInfo.environment["QUENDERIN_MOCK_UI"] == "1"
        #else
        let mockUI = false
        #endif
        let memoryBudget = HardwareProbe.appMemoryBudgetGB()
        let performanceStore = InferencePerformanceStore()
        let engine: InferenceEngine = mockUI
            ? CoordinatedInferenceEngine(MockInferenceEngine())
            : DefaultInferenceEngine.make(deviceBudgetGB: memoryBudget, performance: { sample in
                Task { await performanceStore.record(sample) }
            }) // real LlamaEngine when llama.cpp is linked, else mock
        let downloader: ModelDownloader = mockUI
            ? MockModelDownloader()
            : ParallelRangeDownloader() // real GGUF download — multi-connection ranged (falls back to single-stream)
        // Q-578: onboarding's download gate honors the user's cellular opt-in (Settings → Downloaded
        // models). Off by default → Wi-Fi-only; the live network status comes from the model's own monitor.
        let onboardingModel = OnboardingModel(downloader: downloader, engine: engine, downloadPolicy: { AppSettings.shared.downloadPolicy })
        _onboarding = StateObject(wrappedValue: onboardingModel)
        let automatic = AutomaticModelSelection(onboarding: onboardingModel, store: performanceStore, deviceBudgetGB: memoryBudget)
        // Chat + on-device conversation history: the coordinator owns the ChatModel, restores the
        // most recent conversation on launch, and persists each turn to Application Support.
        let chat = ChatModel(engine: engine, admitTurn: { try onboardingModel.requireReadyForChat() }, prepareFirstTurn: { prompt, current, preparation in
            guard AutomaticModelPreferences.shared.enabled else { return (current, nil) }
            let selected = try await automatic.prepare(prompt: prompt, current: current, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
            return (selected, automatic.status)
        })
        let conversationCoordinator = ConversationCoordinator(chat: chat, persistence: FileConversationPersistence(),
            restoreSelectedModel: { id, preparation in
                try await onboardingModel.restoreConversationModel(id, history: preparation.history, options: preparation.options, isCurrent: preparation.isCurrent)
            })
        _conversations = StateObject(wrappedValue: conversationCoordinator)
        onboardingModel.onManualSelectionCommitted = { model in conversationCoordinator.chooseModelManually(model.id) }
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
        #if os(macOS)
        // A fixed presentation value makes every recovery action focus the same window.
        // Keep WindowGroup's lifetime so closing main while Settings is open does not quit.
        WindowGroup(id: QuenderinMacWindow.id, for: QuenderinMacWindow.Identity.self) { _ in
            RootView(onboarding: onboarding, conversations: conversations, agent: agent)
                .frame(minWidth: 720, minHeight: 560)
                .modifier(QuenderinMacWindowRecovery())
        } defaultValue: {
            .main
        }
        .defaultSize(width: 960, height: 700)
        .commands {
            QuenderinMacWindowCommands(conversations: conversations)
        }
        #else
        WindowGroup {
            RootView(onboarding: onboarding, conversations: conversations, agent: agent)
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
                    }, suspendForSpecialist: { try await onboarding.suspendForSpecialist() })
                } else {
                    Text("Finish setting up Quenderin in the main window first.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
            .frame(minWidth: 680, minHeight: 440)
            .quenderinWindowCanvas()
            .preferredColorScheme(settings.theme.colorScheme)
            // Keep the Dock bridge alive even after the main view has been removed.
            .modifier(QuenderinMacWindowRecovery())
        }
        #endif
    }
}
