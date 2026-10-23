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
    @State private var needsConsent = ConsentGate.needsConsent()
    /// iOS tab selection — programmatic so the chat→agent handoff can jump to the Agent tab.
    @State private var tab = 0
    @State private var showImagesBeforeChat = false
    @State private var showStep5BeforeChat = false
    @StateObject private var step5BeforeChat = Step5Controller()
    @State private var showVisionBeforeChat = false
    @StateObject private var visionBeforeChat: VisionController
    @State private var showGraniteBeforeChat = false
    @StateObject private var graniteBeforeChat: GraniteChatController

    public init(onboarding: OnboardingModel, conversations: ConversationCoordinator, agent: AgentSession? = nil) {
        self.onboarding = onboarding
        self.conversations = conversations
        self.agent = agent
        _visionBeforeChat = StateObject(wrappedValue: VisionController(suspendForSpecialist: { try await onboarding.suspendForSpecialist() }))
        _graniteBeforeChat = StateObject(wrappedValue: GraniteChatController(suspendForSpecialist: { try await onboarding.suspendForSpecialist() }))
    }

    public var body: some View {
        Group {
            if needsWelcome {
                // First launch ever: one calm page of who Quenderin is, before any setup.
                WelcomeView {
                    WelcomeGate.markWelcomed()
                    needsWelcome = false
                }
            } else if needsConsent {
                // Nobody uses the app without agreeing that AI output is their own
                // responsibility — including existing users who predate this screen.
                ConsentView {
                    ConsentGate.markAccepted()
                    needsConsent = false
                }
            } else if case .ready(let model) = onboarding.phase {
                shell(model: model)
                    // Saves stamp the answering model onto the conversation (its list row wears
                    // that family's avatar) — keep the id current across model switches.
                    .task(id: model.id) { conversations.activeModelID = model.id }
            } else {
                OnboardingView(model: onboarding)
                    .overlay(alignment: .topTrailing) {
                        Menu {
                            Button { showVisionBeforeChat = true } label: { Label("Still image", systemImage: "photo.viewfinder") }
                            Button { showStep5BeforeChat = true } label: { Label("Step 5", systemImage: "server.rack") }
                            Button { showImagesBeforeChat = true } label: { Label("Images", systemImage: "photo") }
                            Button { showGraniteBeforeChat = true } label: { Label("Granite 4.1", systemImage: "text.bubble") }
                        } label: { Label("More models", systemImage: "square.stack") }
                            .padding()
                    }
            }
        }
        .quenderinWindowCanvas()
        // Appearance → Theme (nil = follow the system, the default).
        .preferredColorScheme(settings.theme.colorScheme)
        .sheet(isPresented: $showImagesBeforeChat) {
            ImageGenerationView(showsDoneButton: true, suspendForSpecialist: { try await onboarding.suspendForSpecialist() })
                .quenderinSheetWindowCanvas()
        }
        .sheet(isPresented: $showVisionBeforeChat) {
            NavigationStack {
                ScrollView { VisionView(controller: visionBeforeChat).padding() }
                    .quenderinDarkCanvas()
                    .quenderinDarkChrome()
                    .navigationTitle("Still-image questions")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showVisionBeforeChat = false } } }
            }
            .quenderinSheetWindowCanvas()
        }
        .sheet(isPresented: $showGraniteBeforeChat) {
            NavigationStack {
                ScrollView { GraniteChatView(controller: graniteBeforeChat).padding() }
                    .quenderinDarkCanvas()
                    .quenderinDarkChrome()
                    .navigationTitle("Granite Switch 4.1 8B")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGraniteBeforeChat = false } } }
            }
            .quenderinSheetWindowCanvas()
        }
        .sheet(isPresented: $showStep5BeforeChat) {
            NavigationStack {
                ScrollView { Step5View(controller: step5BeforeChat).padding() }
                    .quenderinDarkCanvas()
                    .quenderinDarkChrome()
                    .navigationTitle("Step 5 CUDA host")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showStep5BeforeChat = false } } }
            }
            .quenderinSheetWindowCanvas()
        }
    }

    @ViewBuilder
    private func shell(model: ModelEntry) -> some View {
                #if os(macOS)
                // The Mac gets a native sidebar shell (split view, menu commands, ⌘, Settings) —
                // not the phone's TabView in a window.
                MacRootView(onboarding: onboarding, conversations: conversations, agent: agent, model: model)
                #else
                TabView(selection: $tab) {
                    ChatHomeView(coordinator: conversations, model: model, onSelectModel: { picked in
                        // Same install flow the Settings picker uses: download (if needed) → load → swap.
                        onboarding.beginInstall(picked)
                    })
                        .tabItem { Label("Chat", systemImage: "bubble.left") }
                        .tag(0)
                    if let agent {
                        AgentView(session: agent)
                            .tabItem { Label("Agent", systemImage: "wand.and.stars") }
                            .tag(1)
                    }
                    ImageGenerationView(suspendForSpecialist: { try await onboarding.suspendForSpecialist() })
                        .tabItem { Label("Images", systemImage: "photo") }
                        .tag(5)
                    UniversalSearchView(activeModelID: model.id, onSelectModel: { picked in
                        onboarding.beginInstall(picked)
                    })
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(2)
                    ModelsLibraryView(activeModelID: model.id, onSelectModel: { picked in
                        onboarding.beginInstall(picked)
                    })
                        .tabItem { Label("Models", systemImage: "books.vertical") }
                        .tag(3)
                    SettingsView(coordinator: conversations, model: model, onSelectModel: { picked in
                        // Reuse the onboarding install flow: download (if needed) → load → swap.
                        onboarding.beginInstall(picked)
                    }, suspendForSpecialist: { try await onboarding.suspendForSpecialist() })
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(4)
                }
                // Chat posted a goal via the handoff bar — jump to the Agent tab, which consumes it.
                .onReceive(AgentHandoff.shared.$pending) { pending in
                    if pending != nil, agent != nil { tab = 1 }
                }
                #endif
    }
}
#endif
