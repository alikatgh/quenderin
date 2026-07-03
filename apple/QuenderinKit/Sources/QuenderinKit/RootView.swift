#if canImport(SwiftUI)
import SwiftUI

/// The app root: shows onboarding until a model is ready, then chat (with conversation
/// history) — plus an optional Agent tab when an `AgentSession` is supplied. The app target
/// owns the models (as `@StateObject`, sharing one engine) and passes them in.
public struct RootView: View {
    @ObservedObject private var onboarding: OnboardingModel
    @ObservedObject private var conversations: ConversationCoordinator
    @ObservedObject private var settings = AppSettings.shared
    private let agent: AgentSession?
    @State private var needsWelcome = WelcomeGate.needsWelcome()

    public init(onboarding: OnboardingModel, conversations: ConversationCoordinator, agent: AgentSession? = nil) {
        self.onboarding = onboarding
        self.conversations = conversations
        self.agent = agent
    }

    public var body: some View {
        Group {
            if needsWelcome {
                // First launch ever: one calm page of who Quenderin is, before any setup.
                WelcomeView {
                    WelcomeGate.markWelcomed()
                    needsWelcome = false
                }
            } else if case .ready(let model) = onboarding.phase {
                shell(model: model)
                    // Saves stamp the answering model onto the conversation (its list row wears
                    // that family's avatar) — keep the id current across model switches.
                    .task(id: model.id) { conversations.activeModelID = model.id }
            } else {
                OnboardingView(model: onboarding)
            }
        }
        // Appearance → Theme (nil = follow the system, the default).
        .preferredColorScheme(settings.theme.colorScheme)
    }

    @ViewBuilder
    private func shell(model: ModelEntry) -> some View {
                #if os(macOS)
                // The Mac gets a native sidebar shell (split view, menu commands, ⌘, Settings) —
                // not the phone's TabView in a window.
                MacRootView(onboarding: onboarding, conversations: conversations, agent: agent, model: model)
                #else
                TabView {
                    ChatHomeView(coordinator: conversations, model: model, onSelectModel: { picked in
                        // Same install flow the Settings picker uses: download (if needed) → load → swap.
                        onboarding.beginInstall(picked)
                    })
                        .tabItem { Label("Chat", systemImage: "bubble.left") }
                    if let agent {
                        AgentView(session: agent)
                            .tabItem { Label("Agent", systemImage: "wand.and.stars") }
                    }
                    ModelsLibraryView(activeModelID: model.id, onSelectModel: { picked in
                        onboarding.beginInstall(picked)
                    })
                        .tabItem { Label("Models", systemImage: "books.vertical") }
                    SettingsView(coordinator: conversations, model: model, onSelectModel: { picked in
                        // Reuse the onboarding install flow: download (if needed) → load → swap.
                        onboarding.beginInstall(picked)
                    })
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                #endif
    }
}
#endif
