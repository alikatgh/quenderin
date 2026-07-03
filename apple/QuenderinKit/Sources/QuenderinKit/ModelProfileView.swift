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
    /// When opened FROM a conversation (the chat header), that chat's id — enables the
    /// "This chat" section of per-conversation appearance overrides. nil from the library.
    var conversationID: String? = nil

    /// Plain-language glossary behind the Specifications card's single (?) — this app is for
    /// people who shouldn't need to know what "quantization" means before using it.
    static let glossary: [(String, String)] = [
        ("Parameters", "How big the model is — roughly how much it learned during training. More usually means smarter answers, but a bigger download that needs more memory."),
        ("Download size", "A one-time download. After it finishes, the model is stored on your \(deviceNoun) and works without internet."),
        ("Memory needed", "How much working memory (RAM) the model uses while it's answering. Your \(deviceNoun) needs at least this much free."),
        ("Quantization", "Compression that shrinks the model so it fits on everyday devices. A \"Q4\"-style name means each number is stored in about 4 bits instead of 16 — much smaller, slightly less precise."),
        ("Precision", "How much detail survives the compression. More bits per weight means answers closer to the original model, but a bigger file."),
        ("Quality", "A rough grade of how much the compression affects answer quality — from Low (noticeably simplified) to High (close to the original)."),
        ("Format", "GGUF is the standard file format for AI models that run directly on your \(deviceNoun) instead of in the cloud."),
        ("Checksum", "A digital fingerprint of the downloaded file. Quenderin verifies it so a corrupted or tampered download is never loaded."),
    ]

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

                    if let conversationID {
                        // Per-chat appearance: overrides for THIS conversation only; the global
                        // defaults live in Settings. "Global default" is the reset state.
                        ProfileCard(title: "This chat", palette: p) {
                            ChatPrefsSection(conversationID: conversationID, palette: p)
                        }
                    }

                    // ONE (?) on the card header opens the whole glossary — a ring on every row
                    // read as noise (user feedback), and the terms are best explained together.
                    ProfileCard(title: "Specifications", palette: p, glossary: Self.glossary) {
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
        } else if let logo = vendorLogo(for: modelID) {
            Circle()
                .fill(Color.white)
                .frame(width: size, height: size)
                .overlay(
                    logo.resizable().scaledToFit()
                        .frame(width: size * 0.58, height: size * 0.58)
                )
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
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

/// Per-conversation appearance controls: font + text size, each with a "Global default"
/// choice that clears the override. Writes through ChatPrefsStore immediately — the open
/// transcript re-renders live behind the sheet.
private struct ChatPrefsSection: View {
    let conversationID: String
    let palette: QuenderinPalette
    @ObservedObject private var store = ChatPrefsStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var styleBinding: Binding<AppSettings.ChatFontStyle?> {
        Binding(
            get: { store.fontStyle(for: conversationID).flatMap(AppSettings.ChatFontStyle.init(rawValue:)) },
            set: { store.set(fontStyle: $0?.rawValue, fontSize: store.fontSize(for: conversationID), for: conversationID) }
        )
    }

    private var sizeBinding: Binding<AppSettings.ChatFontSize?> {
        Binding(
            get: { store.fontSize(for: conversationID).flatMap(AppSettings.ChatFontSize.init(rawValue:)) },
            set: { store.set(fontStyle: store.fontStyle(for: conversationID), fontSize: $0?.rawValue, for: conversationID) }
        )
    }

    var body: some View {
        Picker("Chat font", selection: styleBinding) {
            Text("Global default (\(settings.chatFontStyle.label))").tag(AppSettings.ChatFontStyle?.none)
            ForEach(AppSettings.ChatFontStyle.allCases, id: \.self) { style in
                Text(style.label).tag(AppSettings.ChatFontStyle?.some(style))
            }
        }
        Picker("Text size", selection: sizeBinding) {
            Text("Global default (\(settings.chatFontSize.label))").tag(AppSettings.ChatFontSize?.none)
            ForEach(AppSettings.ChatFontSize.allCases, id: \.self) { size in
                Text(size.label).tag(AppSettings.ChatFontSize?.some(size))
            }
        }
        Text("Only this conversation. The defaults for every chat live in Settings.")
            .font(.caption2)
            .foregroundStyle(palette.onSurfaceVariant)
    }
}

/// A captioned, hairline-bordered section card (the picker rows' visual language): the section
/// title sits ABOVE the card as a small uppercase caption, and rows inside carry no separators.
/// Pass a `glossary` to add ONE (?) beside the caption that opens all the term explanations
/// together — per user feedback, a ring on every row reads as noise.
private struct ProfileCard<Content: View>: View {
    let title: String
    let palette: QuenderinPalette
    var glossary: [(String, String)]? = nil
    @ViewBuilder let content: Content
    @State private var showGlossary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .accessibilityAddTraits(.isHeader)
                if let glossary {
                    Button { showGlossary = true } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(palette.onSurfaceVariant.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("What do these mean?")
                    .accessibilityLabel("Explain the \(title.lowercased())")
                    .popover(isPresented: $showGlossary, arrowEdge: .bottom) {
                        GlossaryList(entries: glossary, palette: palette)
                            .compactPopover()
                    }
                }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.onSurfaceVariant.opacity(0.15), lineWidth: 1))
        }
    }
}

/// All the spec terms explained in one place: term (semibold) over one plain-language line each.
private struct GlossaryList: View {
    let entries: [(String, String)]
    let palette: QuenderinPalette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What these mean")
                    .font(.headline)
                ForEach(entries, id: \.0) { term, text in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(term).font(.subheadline.weight(.semibold))
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 440)
    }
}

/// Label on the left (quiet), value on the right (the data is the point — tabular digits, wraps
/// trailing-aligned; `mono` for filenames/checksums). Term explanations live in the card
/// header's single (?) glossary, not on the rows.
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
