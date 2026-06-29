#if canImport(SwiftUI)
import SwiftUI

/// Tier-2 "Advanced — choose a different model" screen. Lists every catalog
/// model and disables the ones that won't fit this device, explaining why.
/// The default flow (OnboardingView) never shows this — choice is opt-in.
public struct ModelPickerView: View {
    private let options: [(model: ModelEntry, fitness: MemoryCheckResult)]
    private let onSelect: (ModelEntry) -> Void

    public init(totalRAMGB: Double, onSelect: @escaping (ModelEntry) -> Void) {
        self.options = ModelCatalog.optionsWithFitness(forTotalRAMGB: totalRAMGB)
        self.onSelect = onSelect
    }

    public var body: some View {
        List(options, id: \.model.id) { option in
            Button {
                onSelect(option.model)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.model.label)
                        Text("\(option.model.sizeLabel) · \(option.model.quantization)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !option.fitness.canLoad {
                            Text(option.fitness.message)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if option.fitness.severity == .safe {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Fits this device")
                    }
                }
            }
            .disabled(!option.fitness.canLoad)
        }
    }
}
#endif
