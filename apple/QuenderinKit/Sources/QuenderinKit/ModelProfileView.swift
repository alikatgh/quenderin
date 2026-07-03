#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform "put this string on the clipboard".
func copyToPasteboard(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

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
            // Card sections instead of a List: a List separator-rules EVERY row (~14 hairlines on
            // this sheet), which reads as a wall of lines. Three bordered cards + captioned
            // headers carry the same structure with a fraction of the ink; rows inside a card
            // need no rules at all (label-left/value-right is separation enough).
            ScrollView {
                VStack(spacing: 18) {
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
                        // The sheet's ONE action, above the fold — not buried under the specs.
                        Button("Change model…") { showPicker = true }
                            .buttonStyle(.borderedProminent)
                            .tint(p.primary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)

                    ProfileCard(title: "Specifications", palette: p) {
                        SpecRow("Parameters", "\(fmt(model.paramsBillions))B", palette: p)
                        SpecRow("Download size", model.sizeLabel.replacingOccurrences(of: " download", with: ""), palette: p)
                        SpecRow("Memory needed", "~\(fmt(model.ramGB)) GB RAM", palette: p)
                        SpecRow("Quantization", model.quantization, palette: p)
                        if let q = quant {
                            SpecRow("Precision", "\(fmt(q.bitsPerWeight)) bits/weight", palette: p)
                            SpecRow("Quality", q.quality, palette: p)
                        }
                        SpecRow("Format", "GGUF", palette: p)
                    }

                    ProfileCard(title: "Technical", palette: p) {
                        SpecRow("File", model.filename, palette: p, mono: true)
                            .contentShape(Rectangle())   // right-click works on the whole row, not just the glyphs
                            .contextMenu {
                                Button("Copy file name") { copyToPasteboard(model.filename) }
                            }
                        if let url = model.downloadURL {
                            Button { openURL(url) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Source").font(.callout).foregroundStyle(p.onSurfaceVariant)
                                    Spacer(minLength: 12)
                                    Text("Hugging Face").font(.callout).foregroundStyle(p.primary)
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(p.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open the model's page on huggingface.co")
                            .accessibilityLabel("Open source page")
                        }
                        // Truncated for display, copyable in full — a hash you can't copy is decoration.
                        SpecRow("Checksum", model.sha256.map { String($0.prefix(12)) + "…" } ?? "magic-only", palette: p, mono: true)
                            .contentShape(Rectangle())
                            .contextMenu {
                                if let sha = model.sha256 {
                                    Button("Copy SHA-256") { copyToPasteboard(sha) }
                                }
                            }
                    }

                    // Prose needs no box and no rules — quiet caption under the cards.
                    Text("Runs entirely on-device via llama.cpp. No account, no cloud, no tracking — "
                       + "once downloaded it works fully offline and nothing you type leaves your \(deviceNoun).")
                        .font(.footnote)
                        .foregroundStyle(p.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(18)
            }
            .background(p.background)
            .navigationTitle("Model")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    ModelPickerView(totalRAMGB: HardwareProbe.current().totalRAMGB, currentModelID: model.id) { picked in
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

/// A captioned, hairline-bordered section card (the picker rows' visual language): the section
/// title sits ABOVE the card as a small uppercase caption, and rows inside carry no separators.
private struct ProfileCard<Content: View>: View {
    let title: String
    let palette: QuenderinPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.onSurfaceVariant)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.onSurfaceVariant.opacity(0.15), lineWidth: 1))
        }
    }
}

/// Label on the left (quiet), value on the right (the data is the point — tabular digits, wraps
/// trailing-aligned; `mono` for filenames/checksums).
private struct SpecRow: View {
    let title: String
    let value: String
    let palette: QuenderinPalette
    let mono: Bool

    init(_ title: String, _ value: String, palette: QuenderinPalette, mono: Bool = false) {
        self.title = title
        self.value = value
        self.palette = palette
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout).foregroundStyle(palette.onSurfaceVariant)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .footnote.monospaced() : .callout.monospacedDigit())
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.trailing)
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
