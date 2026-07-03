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
                        ModelOrb(size: 72, modelID: model.id)
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
                        SpecRow("Parameters", "\(fmt(model.paramsBillions))B", palette: p,
                                hint: "How big the model is — roughly how much it learned during training. More usually means smarter answers, but a bigger download that needs more memory.")
                        SpecRow("Download size", model.sizeLabel.replacingOccurrences(of: " download", with: ""), palette: p,
                                hint: "A one-time download. After it finishes, the model is stored on your \(deviceNoun) and works without internet.")
                        SpecRow("Memory needed", "~\(fmt(model.ramGB)) GB RAM", palette: p,
                                hint: "How much working memory (RAM) the model uses while it's answering. Your \(deviceNoun) needs at least this much free.")
                        SpecRow("Quantization", model.quantization, palette: p,
                                hint: "Compression that shrinks the model so it fits on everyday devices. A \"Q4\"-style name means each number is stored in about 4 bits instead of 16 — much smaller, slightly less precise.")
                        if let q = quant {
                            SpecRow("Precision", "\(fmt(q.bitsPerWeight)) bits/weight", palette: p,
                                    hint: "How much detail survives the compression. More bits per weight means answers closer to the original model, but a bigger file.")
                            SpecRow("Quality", q.quality, palette: p,
                                    hint: "A rough grade of how much the compression affects answer quality — from Low (noticeably simplified) to High (close to the original).")
                        }
                        SpecRow("Format", "GGUF", palette: p,
                                hint: "GGUF is the standard file format for AI models that run directly on your \(deviceNoun) instead of in the cloud.")
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
                        SpecRow("Checksum", model.sha256.map { String($0.prefix(12)) + "…" } ?? "magic-only", palette: p, mono: true,
                                hint: "A digital fingerprint of the downloaded file. Quenderin verifies it so a corrupted or tampered download is never loaded.")
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

/// The model rendered as a chat "contact": a gradient orb with a monogram (twin of Android's
/// `ModelAvatar`). Pass a `modelID` to wear that FAMILY's monogram + brand-inspired colors
/// (see `ModelFamily` — deliberately not the providers' trademarked logos); omit it for the
/// app's own "Q" brand orb.
struct ModelOrb: View {
    let size: CGFloat
    var modelID: String? = nil
    var body: some View {
        let (monogram, top, bottom) = ModelFamily.identity(for: modelID)
        if ModelFamily.isBrand(modelID), let brandAvatar {
            // The app's own identity: the elf mascot from the official icon.
            brandAvatar
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(
                    RadialGradient(
                        colors: [top, bottom],
                        center: .center, startRadius: 0, endRadius: size * 0.7
                    )
                )
                Text(monogram)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
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
/// trailing-aligned; `mono` for filenames/checksums). An optional `hint` adds a small (?) that
/// pops a plain-language explanation — this app is for people who shouldn't need to know what
/// "quantization" means before using it.
private struct SpecRow: View {
    let title: String
    let value: String
    let palette: QuenderinPalette
    let mono: Bool
    let hint: String?
    @State private var showHint = false

    init(_ title: String, _ value: String, palette: QuenderinPalette, mono: Bool = false, hint: String? = nil) {
        self.title = title
        self.value = value
        self.palette = palette
        self.mono = mono
        self.hint = hint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout).foregroundStyle(palette.onSurfaceVariant)
            if let hint {
                Button { showHint = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(palette.onSurfaceVariant.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("What does this mean?")
                .accessibilityLabel("Explain \(title)")
                .popover(isPresented: $showHint, arrowEdge: .bottom) {
                    Text(hint)
                        .font(.callout)
                        .padding(14)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .compactPopover()
                }
            }
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .footnote.monospaced() : .callout.monospacedDigit())
                .foregroundStyle(palette.onSurface)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Keep the explainer a small anchored popover on iPhone too (iOS 16.4+) instead of a
    /// full sheet; a no-op elsewhere (macOS popovers already anchor).
    @ViewBuilder func compactPopover() -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self
        }
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
