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
        return ModelCatalog.models.filter { entry in
            if localIDs.contains(entry.id) { return false }
            if filters.fitsOnly && !MemoryFitness.check(for: entry).canLoad { return false }
            if let maxP = filters.maxParamsB, entry.paramsBillions > maxP + 0.05 { return false }
            return entry.label.lowercased().contains(q)
                || entry.id.lowercased().contains(q)
                || entry.filename.lowercased().contains(q)
        }
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
                            section("On this \(deviceNoun)", color: p.statusText)
                            modelRows(localHits, p: p, showActive: true)
                        }
                        if !catalogHits.isEmpty {
                            section("Catalog", color: p.primary)
                            modelRows(Array(catalogHits.prefix(12)), p: p, showActive: false)
                        }
                        section("Hugging Face (open catalog)", color: p.onSurfaceVariant)
                        Text("Tap a result for details, files, and a link to the model page — no separate window.")
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
            // Newbie presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetChip("All results", active: filters.isDefault, p: p) {
                        filters = .default
                    }
                    presetChip("Runs on this \(deviceNoun)", active: filters == .runsOnThisMac, p: p) {
                        filters = .runsOnThisMac
                    }
                    presetChip("Small & fast", active: filters == .smallAndFast, p: p) {
                        filters = .smallAndFast
                    }
                    presetChip("Best I can run", active: filters == .bestICanRun, p: p) {
                        filters = .bestICanRun
                    }
                    Button {
                        showExpert.toggle()
                    } label: {
                        Label(showExpert ? "Hide filters" : "More filters", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
        bits.append("sort: \(filters.sort.rawValue)")
        return "Active: " + bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func expertFilters(_ p: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $filters.fitsOnly) {
                Text("Only models that fit this \(deviceNoun)’s RAM")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $filters.excludeGated) {
                Text("Hide gated models (need HF license click)")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 12) {
                filterMenu("Max size", selection: maxParamsBinding, options: [
                    (nil, "Any"),
                    (3, "≤ 3B"),
                    (4, "≤ 4B"),
                    (8, "≤ 8B"),
                    (14, "≤ 14B"),
                ], p: p)

                filterMenu("Max download", selection: maxGBBinding, options: [
                    (nil, "Any"),
                    (2, "≤ 2 GB"),
                    (4, "≤ 4 GB"),
                    (6, "≤ 6 GB"),
                    (10, "≤ 10 GB"),
                ], p: p)

                filterMenu("Quant", selection: quantBinding, options: [
                    (nil, "Any"),
                    ("Q4", "Q4"),
                    ("Q5", "Q5"),
                    ("Q6", "Q6"),
                    ("Q8", "Q8"),
                    ("IQ", "IQ"),
                ], p: p)

                Menu {
                    ForEach(ModelSearchFilters.Sort.allCases, id: \.self) { s in
                        Button(s.rawValue) { filters.sort = s }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(12)
        .background(p.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.onSurfaceVariant.opacity(0.12), lineWidth: 1))
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

    private func filterMenu<T: Hashable>(
        _ title: String,
        selection: Binding<T?>,
        options: [(T?, String)],
        p: QuenderinPalette
    ) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button(opt.1) { selection.wrappedValue = opt.0 }
            }
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(p.surface, in: Capsule())
        }
    }

    private func presetChip(_ title: String, active: Bool, p: QuenderinPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? p.primary.opacity(0.18) : p.surface, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(active ? p.primary.opacity(0.5) : p.onSurfaceVariant.opacity(0.15), lineWidth: 1)
                )
                .foregroundStyle(active ? p.primary : p.onSurface)
        }
        .buttonStyle(.plain)
        // Geometry-stable active state (no size change) — UI design rules.
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
            Text("New here? Start with “Runs on this \(deviceNoun)” above, then search a family name. "
               + "Experts: open More filters for params, quant, and sort.")
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
        return Button { onSelectModel(entry) } label: {
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
                    }
                }
                Text(entry.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(p.onSurfaceVariant)
                    .lineLimit(1)
                Text(fit.canLoad ? (fit.severity == .safe ? "Fits" : "Tight") : "Too big")
                    .font(.caption2)
                    .foregroundStyle(fit.canLoad ? p.onSurfaceVariant : .red)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
#endif
