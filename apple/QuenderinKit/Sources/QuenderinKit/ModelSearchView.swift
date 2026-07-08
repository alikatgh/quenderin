#if canImport(SwiftUI)
import SwiftUI

/// The OPEN catalog: search the whole Hugging Face Hub for any GGUF, filtered honestly by what THIS
/// device can run, and download it through the same integrity gate the curated catalog uses (verified
/// against HF's own per-file checksum). Lives at the foot of the Models page — the curated, vetted set
/// stays the default; this is the "I know what I'm doing, show me more" door.
///
/// Honesty is the whole point: every result is labelled a community/third-party upload (not
/// Quenderin-vetted), each quant carries a live Fits / Tight / Too big badge for this Mac, gated repos
/// send you to accept their license rather than silently failing, and nothing becomes your active model
/// until you tap Use.
public struct ModelSearchView: View {
    @StateObject private var controller: ModelSearchController
    @ObservedObject private var library = ModelLibraryController.shared
    private let onSelectModel: (ModelEntry) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var expanded: String?

    public init(onSelectModel: @escaping (ModelEntry) -> Void,
                provider: ModelSearchProviding = HuggingFaceAPI()) {
        self.onSelectModel = onSelectModel
        _controller = StateObject(wrappedValue: ModelSearchController(provider: provider))
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Search the open catalog")
                    .font(.headline).foregroundStyle(p.onSurface)
                Text("Any GGUF on Hugging Face your \(deviceNoun) can run. Community uploads — not vetted by "
                   + "Quenderin, but every download is verified against Hugging Face's own checksum before it runs.")
                    .font(.caption).foregroundStyle(p.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            searchField(p)
            content(p)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private func searchField(_ p: QuenderinPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(p.onSurfaceVariant)
            TextField("Search models — e.g. Qwen, Llama, Phi, Gemma…", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(p.onSurface)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: text) { newValue in controller.search(newValue) }   // single-param form: macOS 13 / iOS 16 safe
                .onSubmit { controller.search(text) }
            if !text.isEmpty {
                Button { text = ""; controller.clear(); expanded = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.callout).foregroundStyle(p.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(p.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private func content(_ p: QuenderinPalette) -> some View {
        switch controller.phase {
        case .idle:
            Text("Search 500,000+ open models. Tip: look for a **GGUF** re-upload (e.g. by TheBloke or "
               + "bartowski) — those are the ready-to-run files, and the smaller quants (Q4) run on more hardware.")
                .font(.caption).foregroundStyle(p.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        case .searching:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching Hugging Face…").font(.callout).foregroundStyle(p.onSurfaceVariant) }
                .padding(.vertical, 4)
        case .empty:
            Text("No GGUF models match “\(controller.query)”. Try a family name like Qwen, Llama, Phi, or Mistral.")
                .font(.callout).foregroundStyle(p.onSurfaceVariant)
        case .error(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(p.onSurfaceVariant)
                Spacer()
                Button("Retry") { controller.search(text) }.buttonStyle(.bordered).controlSize(.small)
            }
        case .results(let hits):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(hits, id: \.id) { hit in
                    RepoRow(hit: hit,
                            isExpanded: expanded == hit.id,
                            quantPhase: controller.quants[hit.id],
                            library: library,
                            palette: p,
                            onToggle: {
                                expanded = (expanded == hit.id) ? nil : hit.id
                                if expanded == hit.id { controller.loadQuants(for: hit.id) }
                            },
                            onGet: { candidate in
                                SideloadedModels.shared.record(candidate)
                                library.download(candidate)
                            },
                            onUse: { candidate in
                                SideloadedModels.shared.record(candidate)
                                onSelectModel(candidate)
                            },
                            onCancel: { candidate in library.cancel(candidate) },
                            onOpenRepo: { if let url = URL(string: "https://huggingface.co/\(hit.id)") { openURL(url) } })
                }
            }
        }
    }
}

/// One repo in the results: identity + download count + a gated badge, expanding to its quants.
private struct RepoRow: View {
    let hit: HFModelHit
    let isExpanded: Bool
    let quantPhase: ModelSearchController.QuantPhase?
    let library: ModelLibraryController
    let palette: QuenderinPalette
    let onToggle: () -> Void
    let onGet: (ModelEntry) -> Void
    let onUse: (ModelEntry) -> Void
    let onCancel: (ModelEntry) -> Void
    let onOpenRepo: () -> Void

    private var owner: String { hit.id.split(separator: "/").first.map(String.init) ?? "" }
    private var name: String { hit.id.split(separator: "/").last.map(String.init) ?? hit.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(palette.onSurfaceVariant).frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(name).font(.callout.weight(.medium)).foregroundStyle(palette.onSurface).lineLimit(1)
                            if hit.gated {
                                Label("Gated", systemImage: "lock").font(.caption2)
                                    .foregroundStyle(Color(hex: 0xE8963A))
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        Text("\(owner) · \(Self.downloads(hit.downloads)) downloads")
                            .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8).padding(.horizontal, 10)

            if isExpanded {
                Divider().overlay(palette.onSurfaceVariant.opacity(0.12))
                quantList
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.onSurfaceVariant.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private var quantList: some View {
        switch quantPhase {
        case .loading, .none:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading files…").font(.caption).foregroundStyle(palette.onSurfaceVariant) }
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(palette.onSurfaceVariant)
        case .loaded(let quants):
            if quants.isEmpty {
                Text("No ready-to-run GGUF files in this repo.").font(.caption).foregroundStyle(palette.onSurfaceVariant)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if hit.gated {
                        Text("This is a gated model — accept its license on Hugging Face first, then download it there. Quenderin never asks for your Hugging Face token.")
                            .font(.caption2).foregroundStyle(Color(hex: 0xE8963A))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(quants) { q in
                        QuantRow(candidate: HuggingFaceCatalog.candidate(from: q, label: "\(name) · \(q.quant)"),
                                 gated: hit.gated, library: library, palette: palette,
                                 onGet: onGet, onUse: onUse, onCancel: onCancel, onOpenRepo: onOpenRepo)
                    }
                }
            }
        }
    }

    /// "271,546" → "272K", 9_000_000 → "9.0M" — compact, honest, tabular.
    static func downloads(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return "\(Int((Double(n) / 1_000).rounded()))K"
        default:           return "\(n)"
        }
    }
}

/// One downloadable quant: quant · size · live fit badge · RAM need, with a state-aware action that
/// reuses the library's download/verify plumbing (so the HF checksum is enforced) and its progress state.
private struct QuantRow: View {
    let candidate: ModelEntry
    let gated: Bool
    let library: ModelLibraryController
    let palette: QuenderinPalette
    let onGet: (ModelEntry) -> Void
    let onUse: (ModelEntry) -> Void
    let onCancel: (ModelEntry) -> Void
    let onOpenRepo: () -> Void

    /// The library controller only auto-detects CURATED files on disk; an HF file downloaded in a prior
    /// session isn't in its state map, so fall back to a direct file-existence check → shows "Use", not "Get".
    private var state: ModelLibraryController.ModelState {
        let live = library.state(of: candidate)
        if case .notInstalled = live {
            let path = OnboardingModel.defaultModelsDir().appendingPathComponent(candidate.filename).path
            if FileManager.default.fileExists(atPath: path) { return .installed }
        }
        return live
    }

    var body: some View {
        let fitness = MemoryFitness.check(for: candidate)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.quantization).font(.caption.monospaced().weight(.medium)).foregroundStyle(palette.onSurface)
                    FitBadge(fitness: fitness, palette: palette)
                }
                Text("\(candidate.sizeLabel) · needs ~\(String(format: "%.1f", candidate.ramGB)) GB RAM")
                    .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer(minLength: 8)
            action(fitness)
        }
    }

    @ViewBuilder
    private func action(_ fitness: MemoryCheckResult) -> some View {
        if gated {
            Button { onOpenRepo() } label: { Label("License", systemImage: "arrow.up.right.square") }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Accept the license on Hugging Face, then download it there")
        } else {
            switch state {
            case .notInstalled:
                Button { onGet(candidate) } label: { Label("Get", systemImage: "arrow.down.circle") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!fitness.canLoad)
                    .help(fitness.canLoad ? "Download and verify this model" : "Too big to load on this \(deviceNoun) — it would run out of memory")
            case .downloading(let fraction):
                HStack(spacing: 6) {
                    ProgressView(value: fraction).frame(width: 70)
                    Button { onCancel(candidate) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Cancel download")
                }
            case .installed:
                Button { onUse(candidate) } label: { Label("Use", systemImage: "checkmark.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(palette.primary)
                    .disabled(!fitness.canLoad)
            case .failed(let reason):
                VStack(alignment: .trailing, spacing: 2) {
                    Button { onGet(candidate) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                    if let reason { Text(reason).font(.caption2).foregroundStyle(palette.onSurfaceVariant).frame(maxWidth: 160).multilineTextAlignment(.trailing) }
                }
            }
        }
    }
}

/// The picker's status-dot fit language (green Fits · orange Tight · red Too big) — the twin of the
/// library page's FitDot, kept local so the two surfaces read identically.
private struct FitBadge: View {
    let fitness: MemoryCheckResult
    let palette: QuenderinPalette

    var body: some View {
        let (color, word): (Color, String) = !fitness.canLoad
            ? (.red, "Too big")
            : fitness.severity == .safe ? (palette.status, "Fits") : (Color(hex: 0xE8963A), "Tight")
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(word).font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
        .accessibilityLabel("Memory fit: \(word)")
    }
}
#endif
