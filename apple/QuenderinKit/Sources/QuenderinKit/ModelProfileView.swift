#if canImport(SwiftUI)
import SwiftUI

/// The model "profile" — the SwiftUI twin of Android's `ModelProfileSheet`. Tapping the chat header
/// (the model name) opens this: a page of everything the app knows about the active model — params,
/// quantization, precision, quality, size, memory, provenance — plus a shortcut to switch models
/// (reusing the fitness-aware `ModelPickerView`). Presented as a sheet from `ChatHomeView`.
///
/// Note: Android's version also hosts a "Deep thinking" toggle; that engine feature is Android-only
/// today (the JNI no-think path), so it's intentionally absent here until iOS gains the same seam.
struct ModelProfileView: View {
    let model: ModelEntry
    var onSelectModel: (ModelEntry) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showPicker = false

    var body: some View {
        let p = QuenderinPalette.of(scheme)
        let quant = Quantization.info(id: model.quantization)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        ModelOrb(size: 72)
                        Text(model.label)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(p.onSurface)
                        HStack(spacing: 6) {
                            Circle().fill(p.status).frame(width: 7, height: 7)
                            Text("on-device · private").font(.footnote).foregroundStyle(p.statusText)
                        }
                        Text(modelBlurb(model.id))
                            .font(.subheadline)
                            .foregroundStyle(p.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }

                Section("Specifications") {
                    SpecRow("Parameters", "\(fmt(model.paramsBillions))B")
                    SpecRow("Download size", model.sizeLabel.replacingOccurrences(of: " download", with: ""))
                    SpecRow("Memory needed", "~\(fmt(model.ramGB)) GB RAM")
                    SpecRow("Quantization", model.quantization)
                    if let q = quant {
                        SpecRow("Precision", "\(fmt(q.bitsPerWeight)) bits/weight")
                        SpecRow("Quality", q.quality)
                    }
                    SpecRow("Format", "GGUF")
                }

                Section("Privacy") {
                    Text("Runs entirely on-device via llama.cpp. No account, no cloud, no tracking — "
                       + "once downloaded it works fully offline and nothing you type leaves your phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Technical") {
                    SpecRow("File", model.filename)
                    if let url = model.downloadURL {
                        Button { openURL(url) } label: {
                            HStack {
                                Text("Source").foregroundStyle(p.onSurface)
                                Spacer()
                                Text("Hugging Face").foregroundStyle(p.primary)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(p.primary)
                            }
                        }
                        .accessibilityLabel("Open source page")
                    }
                    SpecRow("Checksum", model.sha256.map { String($0.prefix(12)) + "…" } ?? "magic-only")
                }

                Section {
                    Button("Change model…") { showPicker = true }
                }
            }
            .navigationTitle("Model")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    ModelPickerView(totalRAMGB: HardwareProbe.current().totalRAMGB) { picked in
                        showPicker = false
                        dismiss()
                        if picked.id != model.id { onSelectModel(picked) }
                    }
                    .navigationTitle("Choose a model")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showPicker = false } }
                    }
                }
            }
        }
    }
}

extension View {
    /// Inline navigation-bar title on iOS; a no-op where `navigationBarTitleDisplayMode` is
    /// unavailable (the macOS build used only as a compile/test harness for this SwiftUI package).
    @ViewBuilder func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// The model rendered as a chat "contact": a gradient orb with a "Q" monogram (twin of Android's
/// `ModelAvatar`).
struct ModelOrb: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [Color(hex: 0x8A82E6), Color(hex: 0x4F46B8)],
                    center: .center, startRadius: 0, endRadius: size * 0.7
                )
            )
            Text("Q")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Label on the left, value on the right (the value wraps/trailing-aligns). A local twin of the
/// `LabeledRow` used in `SettingsView`.
private struct SpecRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Drops a trailing ".0" so 4.0 reads "4" but 3.8 stays "3.8".
private func fmt(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
}

/// One-line, family-specific description keyed off the catalog id. Purely cosmetic copy (twin of
/// Android's `modelBlurb`). Shared with `ModelPickerView`'s rows.
func modelBlurb(_ id: String) -> String {
    if id.hasPrefix("qwen3") { return "Alibaba's Qwen3 — a strong, broadly multilingual all-rounder." }
    if id.hasPrefix("qwen25-coder") { return "Qwen2.5 Coder — tuned for programming and code reasoning." }
    if id.hasPrefix("deepseek-r1") { return "DeepSeek-R1 distilled — a reasoning-focused model that thinks before it answers." }
    if id.hasPrefix("mistral") { return "Mistral — a fast, well-balanced general-purpose model." }
    if id.hasPrefix("gemma3") { return "Google's Gemma 3 — strong multilingual coverage for its size." }
    if id.hasPrefix("phi4") { return "Microsoft's Phi-4 Mini — efficient and capable for its footprint." }
    if id.hasPrefix("llama") { return "Meta's Llama — a capable, general-purpose instruct model." }
    return "An on-device language model running locally via llama.cpp."
}
#endif
