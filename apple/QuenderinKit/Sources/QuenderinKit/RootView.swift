#if canImport(SwiftUI)
import SwiftUI

/// The app root: shows onboarding until a model is ready, then switches to chat.
/// The app target owns the two models (as `@StateObject`, sharing one engine)
/// and passes them in.
public struct RootView: View {
    @ObservedObject private var onboarding: OnboardingModel
    @ObservedObject private var chat: ChatModel

    public init(onboarding: OnboardingModel, chat: ChatModel) {
        self.onboarding = onboarding
        self.chat = chat
    }

    public var body: some View {
        Group {
            if case .ready = onboarding.phase {
                ChatView(model: chat)
            } else {
                OnboardingView(model: onboarding)
            }
        }
    }
}
#endif
