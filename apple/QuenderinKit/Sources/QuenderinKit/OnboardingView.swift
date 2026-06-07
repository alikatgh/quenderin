#if canImport(SwiftUI)
import SwiftUI

/// The first-run screen. Renders `OnboardingModel.phase` and kicks off the probe
/// on appear. Drop it into an Xcode app target's `WindowGroup` (see ROADMAP.md).
public struct OnboardingView: View {
    @ObservedObject private var model: OnboardingModel

    public init(model: OnboardingModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 20) {
            switch model.phase {
            case .probing:
                ProgressView("Checking your device…")

            case let .recommended(entry, hardware, fitness):
                VStack(spacing: 10) {
                    Text("Recommended for your device")
                        .font(.headline)
                    Text(entry.label)
                        .font(.title3.weight(.semibold))

                    if let sel = model.selection {
                        // World-class iPhone pick: device + chip + speed + confidence + alternatives.
                        Text(sel.device.deviceName)
                            .font(.caption).foregroundStyle(.secondary)
                        Label("~\(Int(sel.estimatedTokensPerSecond.rounded())) tok/s · \(sel.device.chip.displayName)",
                              systemImage: "bolt.fill")
                            .font(.caption.monospacedDigit())
                        Group {
                            switch sel.confidence {
                            case .comfortable: Text("Great fit").foregroundStyle(.green)
                            case .tight:       Text("Tight fit").foregroundStyle(.orange)
                            case .forced:      Text("Limited device").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        Text(sel.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if !sel.alternatives.isEmpty {
                            DisclosureGroup("Other options") {
                                ForEach(sel.alternatives, id: \.model.id) { opt in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(opt.model.label)
                                        Spacer()
                                        Text(opt.note).foregroundStyle(.secondary)
                                    }
                                    .font(.caption2)
                                }
                            }
                            .font(.caption)
                        }
                    } else {
                        Text("\(Int(hardware.totalRAMGB.rounded())) GB RAM · \(entry.sizeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !fitness.canLoad {
                            Text(fitness.message)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }

                    Button("Download & Start") {
                        Task { await model.install(entry) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case let .downloading(entry, progress):
                VStack(spacing: 8) {
                    Text("Downloading \(entry.label)…")
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

            case let .loading(entry):
                ProgressView("Loading \(entry.label)…")

            case let .ready(entry):
                VStack(spacing: 8) {
                    Text("Ready")
                        .font(.headline)
                    Text("\(entry.label) is running fully on-device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .failed(message):
                VStack(spacing: 8) {
                    Text("Something went wrong")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .task {
            if case .probing = model.phase { await model.start() }
        }
    }
}
#endif
