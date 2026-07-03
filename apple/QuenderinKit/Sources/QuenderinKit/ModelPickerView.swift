#if canImport(SwiftUI)
import SwiftUI

/// Tier-2 "Advanced — choose a different model" screen, grouped so the first screenful is things
/// you can actually tap: the device's recommendation on top (brand hairline), then every other
/// model that fits, and only at the bottom the ones that don't — each with a structured
/// "not enough memory" card (dot + headline + the two numbers), never a wall of orange text.
/// Rows: name + capability chip · family blurb · monospaced size/quant/RAM meta · explicit fit
/// badge ("Fits" / "Tight" / "Too big") — and "Current" on the active model when the caller
/// passes it. The default flow (OnboardingView) never shows this — choice is opt-in.
public struct ModelPickerView: View {
    private let options: [(model: ModelEntry, fitness: MemoryCheckResult)]
    private let recommendedID: String
    private let currentModelID: String?
    private let onSelect: (ModelEntry) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(totalRAMGB: Double, currentModelID: String? = nil, onSelect: @escaping (ModelEntry) -> Void) {
        self.options = ModelCatalog.optionsWithFitness(forTotalRAMGB: totalRAMGB)
        // Fitness-aware: the tag must sit on a row this same screen can actually install,
        // never on one it dims and disables (band-vs-budget disagreement, e.g. 14B on 16 GB).
        self.recommendedID = ModelRecommender.bestInstallableModel(forTotalRAMGB: totalRAMGB).id
        self.currentModelID = currentModelID
        self.onSelect = onSelect
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        let recommended = options.filter { $0.model.id == recommendedID }
        let fitting = options.filter { $0.model.id != recommendedID && $0.fitness.canLoad }
        let blocked = options.filter { $0.model.id != recommendedID && !$0.fitness.canLoad }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("All of these run fully on your \(deviceNoun) — a one-time download, then it's yours offline.")
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
                    .padding(.horizontal, 4)

                if !recommended.isEmpty {
                    sectionHeader("Recommended for this \(deviceNoun)", color: p.primary)
                    rows(recommended, palette: p)
                }
                if !fitting.isEmpty {
                    sectionHeader("All models", color: p.onSurfaceVariant)
                    rows(fitting, palette: p)
                }
                if !blocked.isEmpty {
                    // Ineligible models sink to the BOTTOM: the sheet opens on choices, not warnings.
                    sectionHeader("Too big for this \(deviceNoun)", color: p.onSurfaceVariant)
                    rows(blocked, palette: p)
                }
            }
            .padding(16)
        }
        .background(p.background)
    }

    @ViewBuilder
    private func rows(_ group: [(model: ModelEntry, fitness: MemoryCheckResult)], palette p: QuenderinPalette) -> some View {
        ForEach(group, id: \.model.id) { option in
            ModelPickerRow(
                model: option.model,
                fitness: option.fitness,
                isRecommended: option.model.id == recommendedID,
                isCurrent: option.model.id == currentModelID,
                palette: p,
                action: { onSelect(option.model) }
            )
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ModelPickerRow: View {
    let model: ModelEntry
    let fitness: MemoryCheckResult
    let isRecommended: Bool
    let isCurrent: Bool
    let palette: QuenderinPalette
    let action: () -> Void

    /// "Qwen3 14B (Best Quality)" → name "Qwen3 14B" + capability chip "Best Quality" — the
    /// parenthetical reads better as a quiet tag than as half the headline.
    private var split: (name: String, tag: String?) {
        guard let open = model.label.range(of: " ("), model.label.hasSuffix(")") else {
            return (model.label, nil)
        }
        let name = String(model.label[..<open.lowerBound])
        let tag = String(model.label[open.upperBound..<model.label.index(before: model.label.endIndex)])
        return (name, tag)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(split.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    if let tag = split.tag {
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(palette.onSurfaceVariant.opacity(0.3), lineWidth: 1))
                    }
                    Spacer(minLength: 10)
                    if isCurrent {
                        // The model you're already running — status-green, same dot+word language.
                        HStack(spacing: 5) {
                            Circle().fill(palette.status).frame(width: 7, height: 7)
                            Text("Current").font(.caption.weight(.medium)).foregroundStyle(palette.statusText)
                        }
                        .accessibilityHidden(true)
                    } else {
                        FitBadge(fitness: fitness, palette: palette)
                    }
                }
                Text(modelBlurb(model.id))
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(model.sizeLabel.replacingOccurrences(of: " download", with: "")) · \(model.quantization) · needs ~\(String(format: "%.1f", model.ramGB)) GB RAM")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.onSurfaceVariant)
                if !fitness.canLoad {
                    MemoryShortfallNote(fitness: fitness, palette: palette)
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
        .disabled(!fitness.canLoad || isCurrent)
        .accessibilityLabel("\(model.label), \(isCurrent ? "current model" : fitLabel(fitness))\(isRecommended ? ", recommended for this device" : "")")
    }
}

/// Why a model can't load, as a compact structured card — orange dot + short headline + ONE
/// plain-toned sentence carrying the two numbers the memory check actually used. The same visual
/// language as onboarding's `StorageShortfallCard`; replaces the previous all-orange paragraph.
private struct MemoryShortfallNote: View {
    let fitness: MemoryCheckResult
    let palette: QuenderinPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("Not enough memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.onSurface)
            }
            Text("Needs ~\(String(format: "%.1f", fitness.requiredMemoryGB)) GB to load — this \(deviceNoun) has \(String(format: "%.1f", fitness.availableMemoryGB)) GB.")
                .font(.caption2)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
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
