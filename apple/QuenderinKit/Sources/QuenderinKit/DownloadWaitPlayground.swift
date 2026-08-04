import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Pure wait content (testable without UI)

/// Rotating one-liners shown while a multi-GB model downloads — keeps the wait useful
/// instead of a dead progress ring. English source of truth; Android twins via string resources.
public enum DownloadWaitTips {
    public static let all: [String] = [
        "Nothing you type will leave this device — the model runs entirely offline.",
        "One download, then airplane mode works. No account. No API keys.",
        "Bigger models think deeper; smaller ones answer faster. You can switch later.",
        "Wi‑Fi recommended: multi‑GB downloads on cellular can cost real money.",
        "When this finishes, chat is private by design — even we can’t see it.",
        "The agent can do pure math offline. Vision/screen tools are opt‑in later.",
        "Heat is the real ceiling on phones, not memory — short chats stay cool.",
        "You can cancel anytime; a partial download resumes next attempt.",
    ]

    /// Tip index for a wall-clock second bucket (stable across UI refreshes in the same second).
    public static func tip(at date: Date = Date(), rotateEverySeconds: TimeInterval = 6) -> String {
        let i = Int(date.timeIntervalSinceReferenceDate / rotateEverySeconds)
        return all[abs(i) % all.count]
    }
}

/// Estimate remaining download time from (time, progress) samples. Pure for unit tests.
public enum DownloadETA {
    /// Returns a short label like "~2 min left", or nil if not enough data.
    public static func estimate(samples: [(Date, Double)], progress: Double, now: Date = Date()) -> String? {
        guard progress > 0.02, progress < 0.99, samples.count >= 2 else { return nil }
        let recent = samples.filter { now.timeIntervalSince($0.0) <= 30 }
        guard let first = recent.first, let last = recent.last else { return nil }
        let dt = last.0.timeIntervalSince(first.0)
        let dp = last.1 - first.1
        guard dt >= 2, dp > 0.005 else { return nil }
        let rate = dp / dt // progress fraction per second
        let remaining = (1.0 - progress) / rate
        guard remaining.isFinite, remaining > 0, remaining < 6 * 3600 else { return nil }
        if remaining < 60 { return "~\(max(1, Int(remaining.rounded())))s left" }
        if remaining < 3600 {
            let m = Int((remaining / 60).rounded())
            return "~\(max(1, m)) min left"
        }
        let h = remaining / 3600
        return String(format: "~%.1f h left", h)
    }
}

/// Lightweight “catch the tokens” arcade state for the download wait screen.
/// Pure value type — UI drives tick/tap; no timers inside.
public struct TokenCatchGame: Equatable, Sendable {
    public struct Token: Equatable, Identifiable, Sendable {
        public let id: Int
        public var x: Double      // 0…1 across the playfield
        public var y: Double      // 0…1 from top
        public var speed: Double  // dy per second
    }

    public private(set) var tokens: [Token] = []
    public private(set) var score: Int = 0
    public private(set) var highScore: Int = 0
    public private(set) var caught: Int = 0
    private var nextID: Int = 1
    private var spawnAccum: Double = 0

    public init() {}

    /// Advance simulation by `dt` seconds.
    public mutating func tick(dt: Double, spawnRate: Double = 1.35) {
        guard dt > 0, dt < 0.5 else { return }
        for i in tokens.indices {
            tokens[i].y += tokens[i].speed * dt
        }
        tokens.removeAll { $0.y > 1.12 }
        spawnAccum += dt * spawnRate
        while spawnAccum >= 1 {
            spawnAccum -= 1
            spawnToken()
        }
    }

    /// Tap at normalized playfield coords (0…1). Returns true if a token was caught.
    @discardableResult
    public mutating func tap(at nx: Double, ny: Double, radius: Double = 0.09) -> Bool {
        guard let idx = tokens.firstIndex(where: {
            let dx = $0.x - nx
            let dy = $0.y - ny
            return (dx * dx + dy * dy) <= radius * radius
        }) else { return false }
        tokens.remove(at: idx)
        score += 1
        caught += 1
        if score > highScore { highScore = score }
        return true
    }

    private mutating func spawnToken() {
        let h = Double((nextID &* 1_103_515_245 &+ 12_345) & 0xFFFF) / Double(0xFFFF)
        let speed = 0.18 + h * 0.28
        tokens.append(Token(id: nextID, x: 0.08 + h * 0.84, y: -0.06, speed: speed))
        nextID += 1
    }
}

// MARK: - SwiftUI playground

#if canImport(SwiftUI)
/// Engagement surface while a model downloads: status, rotating tips, and a casual
/// token-catch mini-game so a multi‑GB wait is not a dead screen.
public struct DownloadWaitPlayground: View {
    let modelLabel: String
    let sizeLabel: String
    let modelID: String?
    let progress: Double
    var onCancel: () -> Void

    @State private var game = TokenCatchGame()
    @State private var etaSamples: [(Date, Double)] = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        modelLabel: String,
        sizeLabel: String,
        modelID: String? = nil,
        progress: Double,
        onCancel: @escaping () -> Void
    ) {
        self.modelLabel = modelLabel
        self.sizeLabel = sizeLabel
        self.modelID = modelID
        self.progress = progress
        self.onCancel = onCancel
    }

    /// Remaining time from recent progress velocity (nil until enough samples).
    private var etaLabel: String? {
        DownloadETA.estimate(samples: etaSamples, progress: progress)
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        let pct = Int((progress * 100).rounded())
        let pctClamped = min(100, max(0, pct))
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ModelAvatar(size: 28, modelID: modelID)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Downloading · \(pctClamped)%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(p.onSurface)
                                .accessibilityAddTraits(.updatesFrequently)
                            if let etaLabel {
                                Text(etaLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(p.onSurfaceVariant)
                            }
                        }
                        Text("\(modelLabel) · \(sizeLabel)")
                            .font(.caption2)
                            .foregroundStyle(p.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .onChange(of: progress) { newProgress in
                    let now = Date()
                    etaSamples.append((now, newProgress))
                    // Keep ~30s of samples
                    etaSamples = etaSamples.filter { now.timeIntervalSince($0.0) < 30 }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.surfaceVariant)
                        Capsule()
                            .fill(p.primary)
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, progress)))))
                    }
                }
                .frame(height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(pctClamped) percent")
                Text("One time — then fully offline. Play while it finishes.")
                    .font(.caption2)
                    .foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surfaceVariant.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.onSurfaceVariant.opacity(0.12), lineWidth: 1))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DownloadWaitTips.tip(at: context.date))
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("While you wait")
                    .accessibilityValue(DownloadWaitTips.tip(at: context.date))
            }

            VStack(spacing: 8) {
                HStack {
                    Text("Catch the tokens")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.onSurface)
                    Spacer()
                    Text("Score \(game.score)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(p.primary)
                        .accessibilityLabel("Score \(game.score)")
                }
                TokenCatchField(game: $game, palette: p, reduceMotion: reduceMotion)
                    .frame(height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Token catch game. Tap glowing tokens as they fall. Score \(game.score).")

                if game.highScore > 0 {
                    Text("Best this wait · \(game.highScore)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(p.onSurfaceVariant)
                }
            }

            Button("Cancel download") { onCancel() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(p.onSurfaceVariant)
                .padding(.top, 2)
        }
    }
}

private struct TokenCatchField: View {
    @Binding var game: TokenCatchGame
    let palette: QuenderinPalette
    let reduceMotion: Bool
    @State private var lastDate: Date = .now

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.05 : 1.0 / 30.0, paused: false)) { context in
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    palette.surfaceVariant.opacity(0.35)
                    if game.tokens.isEmpty && game.score == 0 {
                        Text("Tap the glowing dots")
                            .font(.caption)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                    ForEach(game.tokens) { token in
                        Circle()
                            .fill(palette.primary)
                            .frame(width: 18, height: 18)
                            .position(x: token.x * w, y: token.y * h)
                            // Geometry fixed — no hover transform (UI design rules).
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let nx = Double(value.location.x / max(1, w))
                            let ny = Double(value.location.y / max(1, h))
                            _ = game.tap(at: nx, ny: ny)
                        }
                )
                .onChange(of: context.date) { newDate in
                    let step = min(0.05, newDate.timeIntervalSince(lastDate))
                    lastDate = newDate
                    if step > 0 { game.tick(dt: step) }
                }
                .onAppear { lastDate = context.date }
            }
        }
    }
}
#endif
