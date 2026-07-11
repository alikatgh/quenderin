#if canImport(SwiftUI)
import SwiftUI

/// App-wide Search: one field + newbie presets + expert filters; HF results expand **inline**
/// (details, Hugging Face link, quant table — no popup).
public struct UniversalSearchView: View {
    private let activeModelID: String
    private let onSelectModel: (ModelEntry) -> Void

    @ObservedObject private var library = ModelLibraryController.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var filters = ModelSearchFilters.default
    @State private var showExpert = false

    public init(activeModelID: String, onSelectModel: @escaping (ModelEntry) -> Void) {
        self.activeModelID = activeModelID
        self.onSelectModel = onSelectModel
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var totalRAM: Double { HardwareProbe.current().totalRAMGB }

    private var localHits: [ModelEntry] {
        guard trimmed.count >= 1 else { return [] }
        let q = trimmed.lowercased()
        var seen = Set<String>()
        var out: [ModelEntry] = []
        for entry in ModelCatalog.models + SideloadedModels.shared.all {
            guard library.state(of: entry) == .installed else { continue }
            guard entry.label.lowercased().contains(q) || entry.id.lowercased().contains(q) else { continue }
            if filters.fitsOnly && !MemoryFitness.check(for: entry).canLoad { continue }
            if let maxP = filters.maxParamsB, entry.paramsBillions > maxP + 0.05 { continue }
            if seen.insert(entry.id).inserted { out.append(entry) }
        }
        return out
    }

    private var catalogHits: [ModelEntry] {
        guard trimmed.count >= 1 else { return [] }
        let q = trimmed.lowercased()
        let localIDs = Set(localHits.map(\.id))
        var hits = ModelCatalog.models.filter { entry in
            if localIDs.contains(entry.id) { return false }
            if filters.fitsOnly && !MemoryFitness.check(for: entry).canLoad { return false }
            if let maxP = filters.maxParamsB, entry.paramsBillions > maxP + 0.05 { return false }
            // Soft download gate for curated sizes (sizeLabel is like "4.7 GB").
            if let maxGB = filters.maxDownloadGB {
                let rough = entry.paramsBillions * 0.55
                if rough > maxGB + 0.25 { return false }
            }
            return entry.label.lowercased().contains(q)
                || entry.id.lowercased().contains(q)
                || entry.filename.lowercased().contains(q)
        }
        switch filters.sort {
        case .downloads: break // curated has no download counts — keep catalog order
        case .paramsAsc: hits.sort { $0.paramsBillions < $1.paramsBillions }
        case .paramsDesc: hits.sort { $0.paramsBillions > $1.paramsBillions }
        case .name: hits.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
        return hits
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(spacing: 0) {
            searchChrome(p)
            filterBar(p)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if trimmed.isEmpty {
                        idleHelp(p)
                    } else {
                        if !localHits.isEmpty {
                            section("Already on this \(deviceNoun)", color: p.statusText)
                            Text("Installed — tap Use to switch to that model.")
                                .font(.caption)
                                .foregroundStyle(p.onSurfaceVariant)
                            modelRows(localHits, p: p, showActive: true)
                        }
                        if !catalogHits.isEmpty {
                            section("Quenderin catalog", color: p.primary)
                            Text("Curated models — tap Install to download, or Use if it’s already on disk.")
                                .font(.caption)
                                .foregroundStyle(p.onSurfaceVariant)
                            modelRows(Array(catalogHits.prefix(12)), p: p, showActive: false)
                        }
                        section("Hugging Face (open catalog)", color: p.onSurfaceVariant)
                        Text("Community GGUFs — expand a row, pick a file size, then Get.")
                            .font(.caption)
                            .foregroundStyle(p.onSurfaceVariant)
                        ModelSearchView(
                            onSelectModel: onSelectModel,
                            query: $query,
                            showChrome: false,
                            filters: filters
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
            .background(p.background)
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: Chrome

    @ViewBuilder
    private func searchChrome(_ p: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(p.onSurface)
            Text("Installed models, the curated catalog, and open GGUFs — flexible for beginners and power users.")
                .font(.subheadline)
                .foregroundStyle(p.onSurfaceVariant)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(p.onSurfaceVariant)
                TextField("Search models — e.g. Qwen, Llama 8B, instruct…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(p.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(p.background)
    }

    @ViewBuilder
    private func filterBar(_ p: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Newbie presets + expert disclosure — all hybrid chips (no system bordered style).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    QFilterChip(title: "All results", active: filters.isDefault, palette: p) {
                        filters = .default
                    }
                    QFilterChip(title: "Runs on this \(deviceNoun)", active: filters == .runsOnThisMac, palette: p) {
                        filters = .runsOnThisMac
                    }
                    QFilterChip(title: "Small & fast", active: filters == .smallAndFast, palette: p) {
                        filters = .smallAndFast
                    }
                    QFilterChip(title: "Best I can run", active: filters == .bestICanRun, palette: p) {
                        filters = .bestICanRun
                    }
                    QFilterChip(
                        title: showExpert ? "Hide filters" : "More filters",
                        systemImage: "slider.horizontal.3",
                        active: showExpert,
                        palette: p
                    ) {
                        showExpert.toggle()
                    }
                }
                .padding(.horizontal, 18)
            }

            if showExpert {
                expertFilters(p)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }

            if !filters.isDefault {
                Text(filterSummary)
                    .font(.caption2)
                    .foregroundStyle(p.onSurfaceVariant)
                    .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 8)
        .background(p.background)
    }

    private var filterSummary: String {
        var bits: [String] = []
        if filters.fitsOnly { bits.append("fits this \(deviceNoun)") }
        if filters.excludeGated { bits.append("open license only") }
        if let p = filters.maxParamsB { bits.append("≤ \(Int(p))B") }
        if let g = filters.maxDownloadGB { bits.append("≤ \(Int(g)) GB file") }
        if let q = filters.quantFamily { bits.append(q) }
        bits.append(sortSummary(filters.sort))
        return "Active: " + bits.joined(separator: " · ")
    }

    private func sortSummary(_ s: ModelSearchFilters.Sort) -> String {
        switch s {
        case .downloads: return "sort: downloads"
        case .paramsAsc: return "sort: smallest"
        case .paramsDesc: return "sort: largest"
        case .name: return "sort: name"
        }
    }

    @ViewBuilder
    private func expertFilters(_ p: QuenderinPalette) -> some View {
        QFilterPanel(palette: p) {
            VStack(alignment: .leading, spacing: 12) {
                QFilterToggle(
                    title: "Only models that fit this \(deviceNoun)’s RAM",
                    isOn: $filters.fitsOnly,
                    palette: p
                )
                QFilterToggle(
                    title: "Hide gated models (need HF license click)",
                    isOn: $filters.excludeGated,
                    palette: p
                )

                // Same chip height as presets — native Menu, brand chrome.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        QFilterMenuChip(
                            title: "Max size",
                            selection: maxParamsBinding,
                            options: [
                                (nil, "Any size"),
                                (3.0, "≤ 3B"),
                                (4.0, "≤ 4B"),
                                (8.0, "≤ 8B"),
                                (14.0, "≤ 14B"),
                                (32.0, "≤ 32B"),
                            ],
                            palette: p
                        )
                        QFilterMenuChip(
                            title: "Max download",
                            selection: maxGBBinding,
                            options: [
                                (nil, "Any download"),
                                (2.0, "≤ 2 GB"),
                                (4.0, "≤ 4 GB"),
                                (6.0, "≤ 6 GB"),
                                (10.0, "≤ 10 GB"),
                            ],
                            palette: p
                        )
                        QFilterMenuChip(
                            title: "Quant",
                            selection: quantBinding,
                            options: [
                                (nil, "Any quant"),
                                ("Q4", "Q4"),
                                ("Q5", "Q5"),
                                ("Q6", "Q6"),
                                ("Q8", "Q8"),
                                ("IQ", "IQ"),
                            ],
                            palette: p
                        )
                        QFilterSortChip(sort: $filters.sort, palette: p)
                    }
                }
            }
        }
    }

    private var maxParamsBinding: Binding<Double?> {
        Binding(get: { filters.maxParamsB }, set: { filters.maxParamsB = $0 })
    }
    private var maxGBBinding: Binding<Double?> {
        Binding(get: { filters.maxDownloadGB }, set: { filters.maxDownloadGB = $0 })
    }
    private var quantBinding: Binding<String?> {
        Binding(get: { filters.quantFamily }, set: { filters.quantFamily = $0 })
    }

    @ViewBuilder
    private func idleHelp(_ p: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try searching for")
                .font(.headline)
                .foregroundStyle(p.onSurface)
            ForEach(["Qwen", "Llama", "Gemma", "Phi", "Mistral", "8B instruct"], id: \.self) { tip in
                Button { query = tip } label: {
                    Label(tip, systemImage: "arrow.up.right")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.primary)
            }
            Text("New here? Start with “Runs on this \(deviceNoun)” above, then search a family name. Experts: open More filters for params, quant, and sort.")
                .font(.caption)
                .foregroundStyle(p.onSurfaceVariant)
                .padding(.top, 8)
        }
    }

    private func section(_ title: String, color: Color) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .tracking(0.6)
    }

    @ViewBuilder
    private func modelRows(_ entries: [ModelEntry], p: QuenderinPalette, showActive: Bool) -> some View {
        let cols = [GridItem(.adaptive(minimum: 260), spacing: 12)]
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(entries, id: \.id) { entry in
                searchResultCard(entry, p: p, showActive: showActive)
            }
        }
    }

    private func searchResultCard(_ entry: ModelEntry, p: QuenderinPalette, showActive: Bool) -> some View {
        let isActive = showActive && entry.id == activeModelID
        let border = isActive ? p.primary.opacity(0.5) : p.onSurfaceVariant.opacity(0.12)
        let fit = MemoryFitness.check(for: entry)
        let state = library.state(of: entry)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(p.onSurface)
                            .multilineTextAlignment(.leading)
                        if isActive {
                            Text("Active")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(p.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(p.primary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(entry.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(p.onSurfaceVariant)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(entry.sizeLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(p.onSurfaceVariant)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(p.onSurfaceVariant.opacity(0.5))
                        Text(fit.canLoad ? (fit.severity == .safe ? "Fits this \(deviceNoun)" : "Tight on RAM") : "Too big for this \(deviceNoun)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(fit.canLoad ? p.onSurfaceVariant : .red)
                    }
                }
                Spacer(minLength: 4)
            }

            // Always a real control — never “tap the card and hope”.
            catalogAction(entry: entry, state: state, fit: fit, isActive: isActive, p: p)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func catalogAction(entry: ModelEntry,
                               state: ModelLibraryController.ModelState,
                               fit: MemoryCheckResult,
                               isActive: Bool,
                               p: QuenderinPalette) -> some View {
        switch state {
        case .notInstalled:
            Button {
                onSelectModel(entry)   // beginInstall → download + load
            } label: {
                Label("Install", systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(p.primary)
            .disabled(!fit.canLoad)
            .help(fit.canLoad
                  ? "Download \(entry.label) and make it ready to use"
                  : "Too big for this \(deviceNoun)’s memory")
            .accessibilityLabel("Install \(entry.label)")

        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(maxWidth: .infinity)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(p.onSurfaceVariant)
                Button {
                    library.cancel(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.onSurfaceVariant)
                .accessibilityLabel("Cancel download")
            }

        case .installed:
            if isActive {
                Text("This is the model you’re using now.")
                    .font(.caption)
                    .foregroundStyle(p.onSurfaceVariant)
            } else {
                Button {
                    onSelectModel(entry)
                } label: {
                    Label("Use this model", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(p.primary)
                .disabled(!fit.canLoad)
                .accessibilityLabel("Use \(entry.label)")
            }

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                if let reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(p.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    onSelectModel(entry)
                } label: {
                    Label("Retry install", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityLabel("Retry install \(entry.label)")
            }
        }
    }
}
#endif
