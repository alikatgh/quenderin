#if canImport(SwiftUI)
import SwiftUI

/// The app root: shows onboarding until a model is ready, then chat (with conversation
/// history) — plus an optional Agent tab when an `AgentSession` is supplied. The app target
/// owns the models (as `@StateObject`, sharing one engine) and passes them in.
public struct RootView: View {
    @ObservedObject private var onboarding: OnboardingModel
    @ObservedObject private var conversations: ConversationCoordinator
    private let agent: AgentSession?

    public init(onboarding: OnboardingModel, conversations: ConversationCoordinator, agent: AgentSession? = nil) {
        self.onboarding = onboarding
        self.conversations = conversations
        self.agent = agent
    }

    public var body: some View {
        Group {
            if case .ready = onboarding.phase {
                TabView {
                    ChatHomeView(coordinator: conversations)
                        .tabItem { Label("Chat", systemImage: "bubble.left") }
                    if let agent {
                        AgentView(session: agent)
                            .tabItem { Label("Agent", systemImage: "wand.and.stars") }
                    }
                    AboutView()
                        .tabItem { Label("About", systemImage: "info.circle") }
                }
            } else {
                OnboardingView(model: onboarding)
            }
        }
    }
}
#endif
