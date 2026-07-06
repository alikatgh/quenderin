#if canImport(SwiftUI)
import SwiftUI

/// The Models page — a dedicated destination (Mac rail / iOS tab), not a picker sheet.
/// For people with disk to spare: see the whole catalog, download any or ALL of it up front,
/// and let the router pick per task later. Honest framing everywhere: installed ≠ loadable
/// (RAM still gates what can run), and the storage meter shows real numbers.
public struct ModelsLibraryView: View {
    private let activeModelID: String
    private let onSelectModel: (ModelEntry) -> Void
    @ObservedObject private var library = ModelLibraryController.shared
    @Environment(\.colorScheme) private var scheme
    @State private var confirmDownloadAll = false
    @State private var profileModel: ModelEntry?
    @State private var dropTargeted = false
    @State private var importMessage: String?
    @State private var pendingDelete: ModelEntry?

    public init(activeModelID: String, onSelectModel: @escaping (ModelEntry) -> Void) {
        self.activeModelID = activeModelID
        self.onSelectModel = onSelectModel
    }

    /// The page's information order: what you HAVE, what you SHOULD get, what you COULD get,
    /// what you CAN'T — each its own captioned section, never one undifferentiated dump.
    private var grouped: (mine: [ModelEntry], recommended: [ModelEntry], available: [ModelEntry], blocked: [ModelEntry]) {
        let recommendedID = ModelRecommender.bestInstallableModel(forTotalRAMGB: HardwareProbe.current().totalRAMGB).id
        var mine: [ModelEntry] = [], recommended: [ModelEntry] = []
        var available: [ModelEntry] = [], blocked: [ModelEntry] = []
        for entry in ModelCatalog.models {
            let state = library.state(of: entry)
            if state == .installed || { if case .downloading = state { return true }; return false }() {
                mine.append(entry)   // downloading = arriving — it belongs with "yours"
            } else if entry.id == recommendedID {
                recommended.append(entry)
            } else if MemoryFitness.check(for: entry).canLoad {
                available.append(entry)
            } else {
                blocked.append(entry)
            }
        }
        // Yours: the active model first, then the rest by size (largest = most capable first).
        mine.sort { a, b in
            if (a.id == activeModelID) != (b.id == activeModelID) { return a.id == activeModelID }
            return a.paramsBillions > b.paramsBillions
        }
        return (mine, recommended, available, blocked)
    }

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        let groups = grouped
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(p)

                if !groups.mine.isEmpty {
                    sectionHeader("On this \(deviceNoun)", color: p.statusText, palette: p)
                    grid(groups.mine, palette: p)
                }
                if !groups.recommended.isEmpty {
                    sectionHeader("Recommended", color: p.primary, palette: p,
                                  hint: "The largest model that loads comfortably in this \(deviceNoun)'s "
                                      + "\(Int(HardwareProbe.current().totalRAMGB)) GB of memory — the best answers "
                                      + "it can run without slowdowns. Picked by the same live check that grades "
                                      + "every card's fit badge.")
                    grid(groups.recommended, palette: p)
                }
                if !groups.available.isEmpty {
                    sectionHeader("Available to download", color: p.onSurfaceVariant, palette: p)
                    grid(groups.available, palette: p)
                }
                if !groups.blocked.isEmpty {
                    // Can't-run models sink to the bottom, dimmed by their own cards' fit state.
                    sectionHeader("Too big for this \(deviceNoun)", color: p.onSurfaceVariant, palette: p)
                    grid(groups.blocked, palette: p)
                }

                Text("Installed is not the same as loadable: models load one at a time, and RAM decides "
                   + "which can run. The fit badges are live for this \(deviceNoun). Click a model for its "
                   + "full profile" + (deviceNoun == "Mac" ? ", or drop a .gguf file here to import it." : "."))
                    .font(.footnote)
                    .foregroundStyle(p.onSurfaceVariant)
            }
            .padding(18)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .background(p.background)
        // Drag a .gguf you already have straight onto the page — the power-user import.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "gguf" else { return }
                    Task { @MainActor in
                        switch await library.importGGUF(at: url) {
                        case .installed(let label):
                            importMessage = "\(label) imported — no download needed."
                        case .notInCatalog(let name):
                            importMessage = "\(name) isn't in the catalog yet, so Quenderin can't load it. Custom models are on the roadmap — nothing was copied."
                        case .invalid(let name):
                            importMessage = "\(name) doesn't look like a valid GGUF file — nothing was imported."
                        }
                    }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(p.primary, lineWidth: 2)
                    .background(p.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil },
                                              set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .onAppear { library.refresh() }
        // Click a card → the full profile (specs, glossary, provenance) for THAT model.
        .sheet(item: $profileModel) { entry in
            ModelProfileView(model: entry, onSelectModel: { onSelectModel($0) })
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.label ?? "this model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete (frees \(ByteCountFormatter.string(fromByteCount: library.sizeOnDisk(entry), countStyle: .file)))",
                   role: .destructive) {
                library.delete(entry, activeModelID: activeModelID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("You can download \(entry.label) again any time — it just won't be on this \(deviceNoun).")
        }
        .confirmationDialog(
            "Download \(library.missingModels.count) models (\(library.missingDownloadLabel))?",
            isPresented: $confirmDownloadAll, titleVisibility: .visible
        ) {
            Button("Download all") { library.downloadAllMissing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They download one after another and can be deleted any time in Settings → Storage.")
        }
    }

    @ViewBuilder
    private func grid(_ entries: [ModelEntry], palette p: QuenderinPalette) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 14) {
            ForEach(entries) { entry in
                LibraryRow(
                    entry: entry,
                    state: library.state(of: entry),
                    isActive: entry.id == activeModelID,
                    fitness: MemoryFitness.check(for: entry),
                    palette: p,
                    onDownload: { library.download(entry) },
                    onCancel: { library.cancel(entry) },
                    onUse: { onSelectModel(entry) },
                    onOpen: { profileModel = entry },
                    onDelete: { pendingDelete = entry },
                    sizeOnDisk: library.sizeOnDisk(entry)
                )
            }
        }
    }

    @State private var showRecommendedHint = false

    @ViewBuilder
    private func sectionHeader(_ title: String, color: Color, palette p: QuenderinPalette, hint: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityAddTraits(.isHeader)
            if let hint {
                Button { showRecommendedHint = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(p.onSurfaceVariant.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Why this one?")
                .accessibilityLabel("Why is this recommended?")
                .popover(isPresented: $showRecommendedHint, arrowEdge: .bottom) {
                    Text(hint)
                        .font(.callout)
                        .padding(14)
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func header(_ p: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model library")
                .font(.title2.weight(.semibold))
                .foregroundStyle(p.onSurface)
            Text("\(library.installedCount) of \(ModelCatalog.models.count) installed · \(library.installedSizeLabel) on disk · \(library.freeDiskLabel) free")
                .font(.callout.monospacedDigit())
                .foregroundStyle(p.onSurfaceVariant)
            // The 2 TB-owner move: if everything missing fits comfortably, offer it in one tap.
            if library.canDownloadAllMissing {
                Button {
                    confirmDownloadAll = true
                } label: {
                    Label("Download the complete library (\(library.missingDownloadLabel))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(p.primary)
                .padding(.top, 6)
            }
        }
    }
}

/// One catalog card: identity (vendor logo + name + family blurb) · fit badge · live state
/// (installed / progress / download). The whole card opens the model's profile; the trailing
/// controls act without opening it (buttons capture their own clicks).
private struct LibraryRow: View {
    let entry: ModelEntry
    let state: ModelLibraryController.ModelState
    let isActive: Bool
    let fitness: MemoryCheckResult
    let palette: QuenderinPalette
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onUse: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let sizeOnDisk: Int64
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModelAvatar(size: 40, modelID: entry.id)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    FitDot(fitness: fitness, palette: palette)
                }
                Text(modelBlurb(entry.id))
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(2)
                Text(state == .installed
                     ? "\(ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file)) on disk · \(entry.quantization) · needs ~\(String(format: "%.1f", entry.ramGB)) GB RAM"
                     : "\(entry.sizeLabel) · \(entry.quantization) · needs ~\(String(format: "%.1f", entry.ramGB)) GB RAM")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer(minLength: 12)
            switch state {
            case .installed:
                HStack(spacing: 6) {
                    if isActive {
                        HStack(spacing: 5) {
                            Circle().fill(palette.status).frame(width: 7, height: 7)
                            Text("Active").font(.callout).foregroundStyle(palette.statusText)
                        }
                    } else {
                        Button("Use") { onUse() }
                            .buttonStyle(.bordered)
                            .disabled(!fitness.canLoad)
                            .help(fitness.canLoad ? "Load this model" : "Not enough memory to load on this \(deviceNoun)")
                    }
                    // Manage the file where you SEE the file — not only in Settings → Storage.
                    Menu {
                        #if os(macOS)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [OnboardingModel.defaultModelsDir().appendingPathComponent(entry.filename)])
                        }
                        #endif
                        if isActive {
                            Button("Active — protected") {}.disabled(true)
                        } else {
                            Button("Delete…", role: .destructive) { onDelete() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(entry.label)")
                }
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 90)
                    Button { onCancel() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel download")
                }
            case .notInstalled:
                Button { onDownload() } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .buttonStyle(.bordered)
            case .failed(let reason):
                VStack(alignment: .trailing, spacing: 4) {
                    Button { onDownload() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    if let reason {   // Q-271: say WHY (e.g. blocked on cellular), don't just offer a bare Retry
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover reads through COLOR only (surface tint), never geometry.
        .background(hovering ? palette.surfaceVariant.opacity(0.75) : palette.surfaceVariant,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isActive ? palette.primary.opacity(0.6)
                          : hovering ? palette.primary.opacity(0.35)
                          : palette.onSurfaceVariant.opacity(0.15), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onOpen() }
        // The Mac instinct is RIGHT-CLICK the thing: the whole card answers it with every
        // action the tiny ⋯ has, plus opening the profile — no hunting for the small target.
        .contextMenu {
            Button("Show details…") { onOpen() }
            switch state {
            case .installed:
                if !isActive, fitness.canLoad { Button("Use this model") { onUse() } }
                #if os(macOS)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [OnboardingModel.defaultModelsDir().appendingPathComponent(entry.filename)])
                }
                #endif
                if isActive {
                    Button("Active — protected") {}.disabled(true)
                } else {
                    Button("Delete…", role: .destructive) { onDelete() }
                }
            case .notInstalled, .failed:
                Button("Download") { onDownload() }
            case .downloading:
                Button("Cancel download") { onCancel() }
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(entry.label)'s full profile")
    }
}

/// The picker's status-dot fit language, compact: green Fits · orange Tight · red Too big.
private struct FitDot: View {
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

/// Download/installation state for the library page. Library downloads use the plain
/// URLSession downloader into the SAME models dir the onboarding installer uses, with the
/// same integrity gate — a corrupted download is deleted, never listed as installed.
@MainActor
final class ModelLibraryController: ObservableObject {
    /// One shared instance: downloads must SURVIVE navigating away from the Models page
    /// (a per-view @StateObject deallocated mid-download orphaned its tasks), and the Mac
    /// rail badge observes the same instance for live progress.
    static let shared = ModelLibraryController()

    enum ModelState: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        /// Optional reason shown to the user — the network gate (Q-271) fills it ("on cellular…"),
        /// a transport failure leaves it nil (the generic Retry affordance is enough).
        case failed(String?)
    }

    /// What a dropped .gguf turned out to be (see `importGGUF`).
    enum ImportResult: Equatable {
        case installed(String)      // catalog label — file matched a known model
        case notInCatalog(String)   // filename — we don't quietly hoard disk with unloadable files
        case invalid(String)        // filename — failed the GGUF magic check
    }

    var activeDownloadCount: Int {
        states.values.filter { if case .downloading = $0 { return true }; return false }.count
    }

    /// Mean fraction across live downloads — the rail badge's ring.
    var overallDownloadProgress: Double {
        let fractions = states.values.compactMap { state -> Double? in
            if case .downloading(let f) = state { return f }
            return nil
        }
        guard !fractions.isEmpty else { return 0 }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    /// Import a .gguf the user already has (another machine, a manual download) — the
    /// power-user path that skips a multi-GB download. Catalog-matching filenames only:
    /// a file the engine can never load shouldn't quietly eat disk. Magic-checked before
    /// AND after the copy; a bad copy is deleted, never listed.
    func importGGUF(at url: URL) async -> ImportResult {
        let name = url.lastPathComponent
        guard let entry = ModelCatalog.models.first(where: { $0.filename == name }) else {
            return .notInCatalog(name)
        }
        // The file matched a catalog entry — hold it to that entry's pinned SHA-256 (Q-010),
        // not just the GGUF magic. A tampered or mismatched-quant file with the right NAME must
        // not be trusted as the catalog model. verify() falls back to magic-only when the entry
        // pins no checksum, so an unpinned catalog model still imports.
        guard (try? ModelIntegrity.verify(fileURL: url, expectedSHA256: entry.sha256)) != nil else {
            return .invalid(name)
        }
        states[entry.id] = .downloading(0)
        let destination = modelsDir.appendingPathComponent(entry.filename)
        let dir = modelsDir
        let expectedSHA = entry.sha256
        let copied: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                try ModelIntegrity.verify(fileURL: destination, expectedSHA256: expectedSHA)
                return true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
        }.value
        states[entry.id] = copied ? .installed : .notInstalled
        return copied ? .installed(entry.label) : .invalid(name)
    }

    @Published private(set) var states: [String: ModelState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let downloader: ModelDownloader
    private let modelsDir: URL
    /// Network gate for the library's LIVE downloads (Q-271) — twin of OnboardingModel's. Injected
    /// for tests; live by default via a captured monitor so the gate bites on-device with no wiring.
    private let networkStatus: () -> NetworkStatus
    private let downloadPolicy: () -> DownloadPolicy

    init(
        downloader: ModelDownloader = URLSessionModelDownloader(),
        modelsDir: URL? = nil,
        networkStatus: (() -> NetworkStatus)? = nil,
        downloadPolicy: (() -> DownloadPolicy)? = nil
    ) {
        self.downloader = downloader
        self.modelsDir = modelsDir ?? OnboardingModel.defaultModelsDir()
        if let networkStatus {
            self.networkStatus = networkStatus
        } else {
            #if canImport(Network)
            let monitor = LiveNetworkMonitor()
            self.networkStatus = { monitor.status }   // closure retains the monitor for our lifetime
            #else
            self.networkStatus = { .wifi }
            #endif
        }
        // Q-578: default to the user's setting (Wi-Fi-only unless they opted into cellular) so the
        // library download gate honors the Settings toggle. Tests inject an explicit policy.
        self.downloadPolicy = downloadPolicy ?? { AppSettings.shared.downloadPolicy }
    }

    func refresh() {
        let installed = Set(FileManagerModelStorage(directory: modelsDir).installedFilenames())
        for entry in ModelCatalog.models where tasks[entry.id] == nil {
            states[entry.id] = installed.contains(entry.filename) ? .installed : .notInstalled
        }
    }

    func state(of entry: ModelEntry) -> ModelState { states[entry.id] ?? .notInstalled }

    var installedCount: Int { states.values.filter { $0 == .installed }.count }

    var missingModels: [ModelEntry] {
        ModelCatalog.models.filter {
            switch state(of: $0) { case .notInstalled, .failed: return true; default: return false }
        }
    }

    private var missingBytes: Int64 {
        // sizeLabel is display-only; approximate from the catalog's GB figure in the label.
        missingModels.reduce(0) { $0 + Int64(gbFromSizeLabel($1.sizeLabel) * 1_073_741_824) }
    }

    var missingDownloadLabel: String {
        String(format: "%.1f GB", missingModels.reduce(0.0) { $0 + gbFromSizeLabel($1.sizeLabel) })
    }

    var installedSizeLabel: String {
        let mgr = ModelManager(storage: FileManagerModelStorage(directory: modelsDir), activeModelID: "")
        return ByteCountFormatter.string(fromByteCount: mgr.totalBytesUsed, countStyle: .file)
    }

    var freeDiskLabel: String {
        ByteCountFormatter.string(fromByteCount: DiskSpace.availableBytes(at: modelsDir), countStyle: .file)
    }

    /// Offer "download all" only when everything missing fits with 10 GB of the user's disk
    /// left over — the feature exists FOR the 2 TB crowd, not to wedge a 128 GB laptop.
    var canDownloadAllMissing: Bool {
        !missingModels.isEmpty && missingModels.count > 1
            && DiskSpace.availableBytes(at: modelsDir) > missingBytes + 10_737_418_240
    }

    func downloadAllMissing() {
        // Sequential, as the confirm dialog promises: the first model becomes usable while
        // the rest still download, and N streams don't fight for the same bandwidth.
        let queue = missingModels
        Task { [weak self] in
            for entry in queue {
                guard let self else { return }
                self.download(entry)
                while case .downloading = self.state(of: entry) {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    func download(_ entry: ModelEntry) {
        guard tasks[entry.id] == nil, let url = entry.downloadURL else { return }
        // Network gate (Q-271): twin of OnboardingModel — refuse a multi-GB cellular pull under a
        // Wi-Fi-only policy on the LIVE path, not just in the checklist. Race-free (positive .cellular
        // only, so a warming-up monitor never blocks Wi-Fi). Surfaces the reason on the card.
        if networkStatus() == .cellular, !downloadPolicy().allows(.cellular) {
            states[entry.id] = .failed(downloadPolicy().reason(for: .cellular))
            return
        }
        states[entry.id] = .downloading(0)
        let destination = modelsDir.appendingPathComponent(entry.filename)
        let filename = entry.filename
        tasks[entry.id] = Task { [weak self] in
            // Claim the target file so the onboarding installer can't write the SAME partial
            // concurrently and corrupt it (Q-003). If it's already in flight elsewhere, don't
            // start a second writer — reflect the in-progress state and bail.
            guard await DownloadCoordinator.shared.claim(filename) else {
                self?.states[entry.id] = .downloading(0)
                self?.tasks[entry.id] = nil
                return
            }
            defer { Task { await DownloadCoordinator.shared.release(filename) } }
            do {
                try FileManager.default.createDirectory(at: self?.modelsDir ?? destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                guard let stream = self?.downloader.download(from: url, to: destination) else { return }
                for try await event in stream {
                    switch event {
                    case .progress(let fraction):
                        self?.states[entry.id] = .downloading(fraction)
                    case .finished:
                        try ModelIntegrity.verify(fileURL: destination, expectedSHA256: entry.sha256)
                        self?.states[entry.id] = .installed
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)   // never leave a corrupt file behind
                if !Task.isCancelled { self?.states[entry.id] = .failed(nil) }
            }
            self?.tasks[entry.id] = nil
            if Task.isCancelled { self?.refresh() }
        }
    }

    /// Bytes this model occupies on disk (0 when not installed).
    func sizeOnDisk(_ entry: ModelEntry) -> Int64 {
        let url = modelsDir.appendingPathComponent(entry.filename)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Delete an installed model file. The ACTIVE model is protected — the UI never offers
    /// this for it, and the guard holds even if it did.
    func delete(_ entry: ModelEntry, activeModelID: String) {
        guard entry.id != activeModelID else { return }
        try? FileManager.default.removeItem(at: modelsDir.appendingPathComponent(entry.filename))
        refresh()
    }

    func cancel(_ entry: ModelEntry) {
        tasks[entry.id]?.cancel()
        tasks[entry.id] = nil
        states[entry.id] = .notInstalled
    }

    private func gbFromSizeLabel(_ label: String) -> Double {
        Double(label.split(separator: " ").first ?? "0") ?? 0
    }
}
#endif
