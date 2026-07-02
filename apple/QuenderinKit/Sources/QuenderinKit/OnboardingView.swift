#if canImport(SwiftUI)
import SwiftUI

/// The first-run screen. Renders `OnboardingModel.phase` and kicks off the probe on appear, over an
/// animated "model core" (breathing orb + progress ring) — the SwiftUI twin of Android's redesigned
/// onboarding, on the shared `QuenderinPalette`. Drop it into an Xcode app target's `WindowGroup`.
public struct OnboardingView: View {
    @ObservedObject private var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    public init(model: OnboardingModel) {
        self.model = model
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        ZStack {
            p.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Quenderin")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(p.onSurface)
                Text("An AI that runs on your phone — even offline.")
                    .font(.subheadline)
                    .foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center)

                ModelCoreView(palette: p, progress: downloadProgress, spinning: isProbingOrLoading)
                    .padding(.vertical, 16)

                phaseContent(p)
            }
            .padding(28)
            .frame(maxWidth: 380)
        }
        .task {
            if case .probing = model.phase { await model.start() }
        }
    }

    private var downloadProgress: Double? {
        if case let .downloading(_, progress) = model.phase { return progress }
        return nil
    }
    private var isProbingOrLoading: Bool {
        switch model.phase {
        case .probing, .loading: return true
        default: return false
        }
    }

    @ViewBuilder
    private func phaseContent(_ p: QuenderinPalette) -> some View {
        switch model.phase {
        case .probing:
            Text("Checking your device…")
                .font(.subheadline).foregroundStyle(p.onSurfaceVariant)

        case let .recommended(entry, hardware, fitness):
            VStack(spacing: 8) {
                Text("RECOMMENDED FOR YOUR DEVICE")
                    .font(.caption.weight(.semibold)).foregroundStyle(p.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(entry.label).font(.title3.weight(.semibold)).foregroundStyle(p.onSurface)
                if let sel = model.selection {
                    VStack(spacing: 4) {
                        Label("~\(Int(sel.estimatedTokensPerSecond.rounded())) tok/s · \(sel.device.chip.displayName)",
                              systemImage: "bolt.fill")
                            .font(.caption.monospacedDigit()).foregroundStyle(p.onSurfaceVariant)
                        Text(sel.rationale)
                            .font(.caption).foregroundStyle(p.onSurfaceVariant).multilineTextAlignment(.center)
                        Text(sel.thermalBattery.chatVerdict)
                            .font(.caption2).foregroundStyle(p.onSurfaceVariant).multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                    if !sel.alternatives.isEmpty {
                        DisclosureGroup("Other options") {
                            ForEach(sel.alternatives, id: \.model.id) { opt in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(opt.model.label)
                                    Spacer()
                                    Text(opt.note).foregroundStyle(p.onSurfaceVariant)
                                }
                                .font(.caption2)
                            }
                        }
                        .font(.caption).tint(p.primary)
                    }
                } else {
                    Text("\(Int(hardware.totalRAMGB.rounded())) GB RAM · \(entry.sizeLabel)")
                        .font(.caption).foregroundStyle(p.onSurfaceVariant)
                    if !fitness.canLoad {
                        Text(fitness.message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                }
                Button("Download & continue") { Task { await model.install(entry) } }
                    .buttonStyle(.borderedProminent)
                    .tint(p.primary)
                    .padding(.top, 4)
            }

        case let .downloading(entry, _):
            VStack(spacing: 4) {
                Text("Downloading").font(.caption).foregroundStyle(p.onSurfaceVariant)
                Text(entry.label).font(.headline).foregroundStyle(p.onSurface)
                Text("\(entry.sizeLabel) · one time, then it's yours offline")
                    .font(.caption).foregroundStyle(p.onSurfaceVariant).multilineTextAlignment(.center)
            }

        case let .loading(entry):
            Text("Warming up \(entry.label)…")
                .font(.subheadline).foregroundStyle(p.onSurfaceVariant)

        case let .ready(entry):
            VStack(spacing: 6) {
                Text("Ready").font(.headline).foregroundStyle(p.onSurface).accessibilityAddTraits(.isHeader)
                Text("\(entry.label) is running fully on-device.")
                    .font(.caption).foregroundStyle(p.onSurfaceVariant)
            }

        case let .failed(message):
            VStack(spacing: 8) {
                Text("Couldn't get set up").font(.headline).foregroundStyle(p.onSurface)
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }
}

/// Animated brand mark drawn with Canvas (no assets): a breathing core, rippling activity rings, and a
/// determinate progress ring during download / a scan sweep while probing. Twin of Android's ModelCore.
private struct ModelCoreView: View {
    let palette: QuenderinPalette
    var progress: Double? = nil
    var spinning: Bool = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2

                func circleRect(_ r: Double) -> CGRect {
                    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                }

                // Soft glow.
                ctx.fill(
                    Circle().path(in: circleRect(maxR)),
                    with: .radialGradient(
                        Gradient(colors: [palette.primary.opacity(0.28), palette.primary.opacity(0)]),
                        center: c, startRadius: 0, endRadius: maxR
                    )
                )

                // Rippling rings.
                let ripple = (t / 2.8).truncatingRemainder(dividingBy: 1)
                for i in 0..<3 {
                    let ph = (ripple + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let r = maxR * (0.34 + ph * 0.62)
                    ctx.stroke(Circle().path(in: circleRect(r)),
                               with: .color(palette.primary.opacity((1 - ph) * 0.30)), lineWidth: 1.5)
                }

                // Progress ring (download) or scan sweep (probing/loading).
                let ringR = maxR * 0.66
                if let prog = progress {
                    ctx.stroke(Circle().path(in: circleRect(ringR)),
                               with: .color(palette.primary.opacity(0.15)),
                               style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    let arc = Path { $0.addArc(center: c, radius: ringR, startAngle: .degrees(-90),
                                               endAngle: .degrees(-90 + 360 * max(0, min(1, prog))), clockwise: false) }
                    ctx.stroke(arc, with: .color(palette.primary), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                } else if spinning {
                    ctx.stroke(Circle().path(in: circleRect(ringR)),
                               with: .color(palette.primary.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    let start = (t * 257).truncatingRemainder(dividingBy: 360)
                    let arc = Path { $0.addArc(center: c, radius: ringR, startAngle: .degrees(start),
                                               endAngle: .degrees(start + 90), clockwise: false) }
                    ctx.stroke(arc, with: .color(palette.primary), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }

                // Breathing core.
                let breathe = 0.92 + 0.06 * (0.5 + 0.5 * sin(t * 1.2))
                let coreR = maxR * 0.30 * breathe
                ctx.fill(
                    Circle().path(in: circleRect(coreR)),
                    with: .radialGradient(
                        Gradient(colors: [palette.primary, palette.primary.opacity(0.65)]),
                        center: c, startRadius: 0, endRadius: coreR
                    )
                )
            }
            .frame(width: 190, height: 190)
            .overlay {
                if let prog = progress {
                    Text("\(Int(prog * 100))%")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                }
            }
        }
    }
}
#endif
