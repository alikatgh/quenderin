#if canImport(SwiftUI)
import SwiftUI

/// The app root: shows onboarding until a model is ready, then chat — plus an optional
/// Agent tab when an `AgentSession` is supplied. The app target owns the models (as
/// `@StateObject`, sharing one engine) and passes them in.
public struct RootView: View {
    @ObservedObject private var onboarding: OnboardingModel
    @ObservedObject private var chat: ChatModel
    private let agent: AgentSession?

    public init(onboarding: OnboardingModel, chat: ChatModel, agent: AgentSession? = nil) {
        self.onboarding = onboarding
        self.chat = chat
        self.agent = agent
    }

    public var body: some View {
        Group {
            if case .ready = onboarding.phase {
                if let agent {
                    TabView {
                        ChatView(model: chat)
                            .tabItem { Label("Chat", systemImage: "bubble.left") }
                        AgentView(session: agent)
                            .tabItem { Label("Agent", systemImage: "wand.and.stars") }
                    }
                } else {
                    ChatView(model: chat)
                }
            } else {
                OnboardingView(model: onboarding)
            }
        }
    }
}
#endif
