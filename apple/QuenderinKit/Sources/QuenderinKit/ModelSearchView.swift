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
    /// When non-nil, the parent owns the search field (e.g. Universal Search rail) — we hide chrome + field.
    private var externalQuery: Binding<String>?
    private let showChrome: Bool
    private let filters: ModelSearchFilters
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var localText = ""
    @State private var expanded: String?

    public init(onSelectModel: @escaping (ModelEntry) -> Void,
                provider: ModelSearchProviding = HuggingFaceAPI(),
                query: Binding<String>? = nil,
                showChrome: Bool = true,
                filters: ModelSearchFilters = .default) {
        self.onSelectModel = onSelectModel
        self.externalQuery = query
        self.showChrome = showChrome
        self.filters = filters
        _controller = StateObject(wrappedValue: ModelSearchController(provider: provider))
    }

    private var totalRAM: Double { HardwareProbe.current().totalRAMGB }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        Group {
            if showChrome {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Search the open catalog")
                            .font(.headline).foregroundStyle(p.onSurface)
                        Text("Any GGUF on Hugging Face your \(deviceNoun) can run. Community uploads — not vetted by Quenderin, but every download is verified against Hugging Face's own checksum before it runs.")
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
            } else {
                content(p)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            // Parent (Universal Search) often mounts us with a query already typed — onChange
            // does not fire for the initial value, so without this HF stays stuck on the idle tip.
            let q = textBinding.wrappedValue
            if q.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                controller.search(q)
            }
        }
        .onChange(of: textBinding.wrappedValue) { newValue in
            controller.search(newValue)
        }
    }

    @ViewBuilder
    private func searchField(_ p: QuenderinPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(p.onSurfaceVariant)
            TextField("Search models — e.g. Qwen, Llama, Phi, Gemma…", text: textBinding)
                .textFieldStyle(.plain)
                .foregroundStyle(p.onSurface)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: textBinding.wrappedValue) { newValue in controller.search(newValue) }
                .onSubmit { controller.search(textBinding.wrappedValue) }
            if !textBinding.wrappedValue.isEmpty {
                Button {
                    textBinding.wrappedValue = ""
                    controller.clear()
                    expanded = nil
                } label: {
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

    private var textBinding: Binding<String> {
        if let externalQuery { return externalQuery }
        return $localText
    }

    private func filterCountLine(shown: Int, total: Int) -> String {
        if shown == total {
            return "\(shown) model\(shown == 1 ? "" : "s") · tap a row → Show files → Get"
        }
        return "\(shown) of \(total) match filters · tap a row → Show files → Get"
    }

    @ViewBuilder
    private func content(_ p: QuenderinPalette) -> some View {
        switch controller.phase {
        case .idle:
            if showChrome {
                Text("Type at least 2 characters. Tip: look for a GGUF re-upload (e.g. TheBloke or bartowski) — those are ready-to-run files; smaller quants (Q4) fit more hardware.")
                    .font(.caption).foregroundStyle(p.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Embedded under Universal Search — never leave a dead tip with no control.
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(p.onSurfaceVariant)
                    Text(textBinding.wrappedValue.count < 2
                         ? "Type at least 2 characters above to search open models on Hugging Face."
                         : "Starting Hugging Face search…")
                        .font(.callout)
                        .foregroundStyle(p.onSurfaceVariant)
                }
                .padding(.vertical, 6)
            }
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching Hugging Face…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(p.onSurface)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Searching Hugging Face")
        case .empty:
            VStack(alignment: .leading, spacing: 6) {
                Text("No open GGUF models match “\(controller.query)”.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(p.onSurface)
                Text("Try a family name like Qwen, Llama, Phi, or Mistral — or clear filters above.")
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
            }
        case .error(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(p.onSurfaceVariant)
                Spacer()
                Button("Retry") { controller.search(textBinding.wrappedValue) }
                    .buttonStyle(.borderedProminent)
                    .tint(p.primary)
                    .controlSize(.small)
            }
        case .results(let hits):
            let shown = filters.apply(to: hits, totalRAMGB: totalRAM)
            if shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(hits.count) model\(hits.count == 1 ? "" : "s") found — none match your filters.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(p.onSurface)
                    Text("Tap “All results”, turn off “fits RAM”, or raise max size / download.")
                        .font(.caption)
                        .foregroundStyle(p.onSurfaceVariant)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Make filter effect obvious: "3 of 17 match filters" vs silent no-op.
                    Text(filterCountLine(shown: shown.count, total: hits.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(p.onSurfaceVariant)
                    if filters.quantFamily != nil || filters.maxDownloadGB != nil {
                        Text("Quant & exact file size also refine files after you tap Show files.")
                            .font(.caption2)
                            .foregroundStyle(p.onSurfaceVariant)
                    }
                    ForEach(shown, id: \.id) { hit in
                        RepoRow(hit: hit,
                                isExpanded: expanded == hit.id,
                                quantPhase: controller.quants[hit.id],
                                filters: filters,
                                totalRAMGB: totalRAM,
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
                                onOpenRepo: { if let url = hit.hubURL { openURL(url) } })
                    }
                }
            }
        }
    }
}

/// One repo: tap header to expand **inline** (no popup) — blurb, HF link, quant table.
private struct RepoRow: View {
    let hit: HFModelHit
    let isExpanded: Bool
    let quantPhase: ModelSearchController.QuantPhase?
    let filters: ModelSearchFilters
    let totalRAMGB: Double
    let library: ModelLibraryController
    let palette: QuenderinPalette
    let onToggle: () -> Void
    let onGet: (ModelEntry) -> Void
    let onUse: (ModelEntry) -> Void
    let onCancel: (ModelEntry) -> Void
    let onOpenRepo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Full-width header — whole row is tappable for expand/collapse.
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .frame(width: 14, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(hit.shortName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(palette.onSurface)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            if hit.gated {
                                Label("Gated", systemImage: "lock")
                                    .font(.caption2)
                                    .foregroundStyle(Color(hex: 0xE8963A))
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        Text("\(hit.owner) · \(Self.downloads(hit.downloads)) downloads"
                           + (hit.likes > 0 ? " · \(Self.downloads(hit.likes)) likes" : "")
                           + " · ~\(Self.paramsLabel(hit.estimatedParamsB))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(2)
                        if !isExpanded {
                            Text("Tap to expand → pick a file → Get")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(palette.primary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(isExpanded ? "Hide" : "Show files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.primary.opacity(0.12), in: Capsule())
                }
                .contentShape(Rectangle())
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(hit.shortName), \(isExpanded ? "collapse" : "expand") details")
            .accessibilityHint(isExpanded ? "Hides downloadable files" : "Shows downloadable files and Get buttons")

            if isExpanded {
                Divider().overlay(palette.onSurfaceVariant.opacity(0.12))
                detailPanel
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(palette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isExpanded ? palette.primary.opacity(0.35) : palette.onSurfaceVariant.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hit.detailBlurb)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            // Always-visible external links (no popup — browser / HF site).
            HStack(spacing: 10) {
                Button(action: onOpenRepo) {
                    Label("Open on Hugging Face", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Model card, license, discussions on huggingface.co")

                if let url = hit.hubURL {
                    // Shareable path for experts who want the exact repo id.
                    Text(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            quantList
        }
    }

    @ViewBuilder
    private var quantList: some View {
        switch quantPhase {
        case .loading, .none:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading downloadable files…").font(.caption).foregroundStyle(palette.onSurfaceVariant)
            }
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(palette.onSurfaceVariant)
        case .loaded(let raw):
            let quants = filters.apply(to: raw, totalRAMGB: totalRAMGB)
            if raw.isEmpty {
                Text("No ready-to-run GGUF files in this repo.")
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant)
            } else if quants.isEmpty {
                Text("No files match your filters for this model. Clear quant/size filters or turn off “Fits only”.")
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if hit.gated {
                        Text("Gated model — accept its license on Hugging Face first. Quenderin never asks for your HF token.")
                            .font(.caption2).foregroundStyle(Color(hex: 0xE8963A))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let pick = ModelSearchFilters.recommendedPick(from: raw, totalRAMGB: totalRAMGB) {
                        let entry = HuggingFaceCatalog.candidate(from: pick, label: pick.quant)
                        let fit = MemoryFitness.check(for: entry)
                        if fit.canLoad {
                            Text("Suggested on this \(deviceNoun): \(pick.quant) · \(entry.sizeLabel) · \(fit.severity == .safe ? "Fits" : "Tight")")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.primary)
                        }
                    }
                    Text("Files")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                    ForEach(quants) { q in
                        QuantRow(
                            candidate: HuggingFaceCatalog.candidate(from: q, label: "\(hit.shortName) · \(q.quant)"),
                            gated: hit.gated, library: library, palette: palette,
                            onGet: onGet, onUse: onUse, onCancel: onCancel, onOpenRepo: onOpenRepo
                        )
                    }
                }
            }
        }
    }

    static func downloads(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return "\(Int((Double(n) / 1_000).rounded()))K"
        default:           return "\(n)"
        }
    }

    static func paramsLabel(_ p: Double) -> String {
        p == floor(p) ? "\(Int(p))B" : String(format: "%.1fB", p)
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
                Button { onGet(candidate) } label: {
                    Label("Get", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.primary)
                .controlSize(.small)
                .disabled(!fitness.canLoad)
                .help(fitness.canLoad ? "Download and verify this model" : "Too big to load on this \(deviceNoun) — it would run out of memory")
                .accessibilityLabel("Get \(candidate.quantization)")
            case .downloading(let fraction):
                HStack(spacing: 6) {
                    ProgressView(value: fraction).frame(width: 70)
                    Button { onCancel(candidate) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Cancel download")
                }
            case .installed:
                Button { onUse(candidate) } label: {
                    Label("Use", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(palette.primary)
                .disabled(!fitness.canLoad)
                .accessibilityLabel("Use \(candidate.quantization)")
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
