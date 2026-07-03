#if canImport(SwiftUI)
import SwiftUI

/// Tier-2 "Advanced — choose a different model" screen. Lists every catalog model as a design-system
/// card: family blurb, size/quant/RAM meta, and an EXPLICIT fit badge ("Fits" / "Tight" / "Too big")
/// instead of an unexplained checkmark. The device's recommended model carries a brand-tinted border +
/// tag. Models that can't load are dimmed, disabled, and say why. The default flow (OnboardingView)
/// never shows this — choice is opt-in.
public struct ModelPickerView: View {
    private let options: [(model: ModelEntry, fitness: MemoryCheckResult)]
    private let recommendedID: String
    private let onSelect: (ModelEntry) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(totalRAMGB: Double, onSelect: @escaping (ModelEntry) -> Void) {
        self.options = ModelCatalog.optionsWithFitness(forTotalRAMGB: totalRAMGB)
        // Fitness-aware: the tag must sit on a row this same screen can actually install,
        // never on one it dims and disables (band-vs-budget disagreement, e.g. 14B on 16 GB).
        self.recommendedID = ModelRecommender.bestInstallableModel(forTotalRAMGB: totalRAMGB).id
        self.onSelect = onSelect
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("All of these run fully on your \(deviceNoun) — a one-time download, then it's yours offline.")
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
                    .padding(.horizontal, 4)
                ForEach(options, id: \.model.id) { option in
                    ModelPickerRow(
                        model: option.model,
                        fitness: option.fitness,
                        isRecommended: option.model.id == recommendedID,
                        palette: p,
                        action: { onSelect(option.model) }
                    )
                }
            }
            .padding(16)
        }
        .background(p.background)
    }
}

private struct ModelPickerRow: View {
    let model: ModelEntry
    let fitness: MemoryCheckResult
    let isRecommended: Bool
    let palette: QuenderinPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    FitBadge(fitness: fitness, palette: palette)
                }
                Text(modelBlurb(model.id))
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(model.sizeLabel.replacingOccurrences(of: " download", with: "")) · \(model.quantization) · needs ~\(String(format: "%.1f", model.ramGB)) GB RAM")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.onSurfaceVariant)
                if isRecommended {
                    Text("RECOMMENDED FOR THIS DEVICE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.primary)
                }
                if !fitness.canLoad {
                    Text(fitness.message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                // Hairline border; brand-tinted on the recommended card (color changes, never geometry).
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isRecommended ? palette.primary.opacity(0.6) : palette.onSurfaceVariant.opacity(0.15), lineWidth: 1)
            )
            .opacity(fitness.canLoad ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!fitness.canLoad)
        .accessibilityLabel("\(model.label), \(fitLabel(fitness))\(isRecommended ? ", recommended for this device" : "")")
    }
}

/// The explicit fit verdict — a status dot + word, the same visual language as the chat header's
/// "on-device · private". Green "Fits", orange "Tight", red "Too big".
private struct FitBadge: View {
    let fitness: MemoryCheckResult
    let palette: QuenderinPalette

    var body: some View {
        let (color, text): (Color, String) = {
            if !fitness.canLoad { return (.red, "Too big") }
            switch fitness.severity {
            case .safe: return (palette.status, "Fits")
            default: return (.orange, "Tight")
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .accessibilityHidden(true)   // folded into the row's accessibilityLabel
    }
}

private func fitLabel(_ fitness: MemoryCheckResult) -> String {
    if !fitness.canLoad { return "too big for this device" }
    return fitness.severity == .safe ? "fits this device" : "tight on this device"
}
#endif
