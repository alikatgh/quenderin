import XCTest
import SwiftUI
@testable import QuenderinKit

/// Renders the REAL app views to PNGs for the marketing site — no hand-faked CSS mockups.
/// Skipped in normal test runs; enable with:
///
///   QUENDERIN_RENDER_ASSETS=/abs/path/to/website/assets/app swift test --filter WebsiteAssetRender
///
/// Regenerate whenever the UI changes so the site never drifts from the product
/// (the drift was exactly what made the old site read as AI-slop).
@MainActor
final class WebsiteAssetRenderTests: XCTestCase {

    func testRenderWebsiteAssets() async throws {
        guard let outDir = ProcessInfo.processInfo.environment["QUENDERIN_RENDER_ASSETS"] else {
            throw XCTSkip("set QUENDERIN_RENDER_ASSETS=<output dir> to render website assets")
        }
        let out = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let llama = ModelCatalog.models.first { $0.id.hasPrefix("llama") } ?? ModelCatalog.smallest

        // 1. Chat — a staged transcript that shows the anatomy: user bubble right, Markdown +
        // highlighted code in the reply, model header identity above.
        let chat = ChatModel(engine: ScriptedInferenceEngine(replies: []))
        chat.restore([
            ChatMessage(role: .user, text: "Teach me Python in three short steps"),
            ChatMessage(role: .assistant, text: """
            **Step 1 — Say hello.** Every Python journey starts here:

            ```python
            # your first program
            print("Hello, world!")
            ```

            **Step 2 — Remember things.** Variables hold your data:

            ```python
            name = "Ada"
            age = 36
            print(f"{name} is {age}")
            ```

            **Step 3 — Repeat yourself.** Loops do the boring work:

            ```python
            for day in ["mon", "tue", "wed"]:
                print("plan for", day)
            ```

            That's the core — everything else builds on these three.
            """),
        ])
        try render(ChatView(model: chat).frame(width: 720, height: 580), to: out, name: "chat")

        // 2. Welcome — the first-launch page (elf, three value props).
        try render(WelcomeView(onContinue: {}).frame(width: 520, height: 720), to: out, name: "welcome")

        // 3. Model profile — identity + specs card with the single (?) glossary header.
        try render(ModelProfileView(model: llama, onSelectModel: { _ in }).frame(width: 520, height: 820),
                   to: out, name: "profile")

        // 4. Model picker — the fitness-aware catalog (Fits / Tight / Too big).
        try render(ModelPickerView(totalRAMGB: 16, currentModelID: llama.id, onSelect: { _ in })
                       .frame(width: 520, height: 820),
                   to: out, name: "picker")

        // 5. Agent — a REAL run through the actual AgentLoop (scripted planner, real tools),
        // showing the run log + answer anatomy.
        let agentEngine = ScriptedInferenceEngine(replies: [
            #"{"tool":"units","input":"5 miles to km"}"#,
            #"{"tool":"calculator","input":"8.0467 * 0.20"}"#,
            #"{"answer":"5 miles is **8.05 km**, and 20% of that is **1.61 km**."}"#,
        ])
        let session = AgentSession(engine: agentEngine, tools: [CalculatorTool(), UnitConverterTool()])
        await session.run(goal: "Convert 5 miles to km, then take 20% of that")
        try render(AgentView(session: session).frame(width: 720, height: 560), to: out, name: "agent")
    }

    /// Snapshot via a real (briefly materialized, back-ordered) NSHostingView window —
    /// ImageRenderer can't draw AppKit-backed SwiftUI (TextField, ScrollView content),
    /// which is exactly what a chat screen is made of.
    private func render(_ view: some View, to dir: URL, name: String) throws {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)   // honors the .frame() at the call site
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)   // on-screen (behind everything) so the backing store is Retina 2x
        defer { window.orderOut(nil) }
        // Let SwiftUI run its layout/async passes (lazy stacks, scroll content) before caching.
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("no bitmap rep for \(name)"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("no png for \(name)"); return
        }
        let url = dir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("rendered \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
}
