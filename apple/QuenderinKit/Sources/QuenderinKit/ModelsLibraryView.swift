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

    public var body: some View {
        let p = QuenderinPalette.of(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(p)
                // Adaptive grid: one column in a narrow window, two on a wide Mac pane —
                // cards, not a strip down the middle of a big window.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(ModelCatalog.models) { entry in
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
            case .failed:
                Button { onDownload() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .tint(.orange)
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
        case failed
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
        guard (try? ModelIntegrity.verify(fileURL: url, expectedSHA256: nil)) != nil else {
            return .invalid(name)
        }
        states[entry.id] = .downloading(0)
        let destination = modelsDir.appendingPathComponent(entry.filename)
        let dir = modelsDir
        let copied: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                try ModelIntegrity.verify(fileURL: destination, expectedSHA256: nil)
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
    private let downloader = URLSessionModelDownloader()
    private let modelsDir = OnboardingModel.defaultModelsDir()

    func refresh() {
        let installed = Set(FileManagerModelStorage(directory: modelsDir).installedFilenames())
        for entry in ModelCatalog.models where tasks[entry.id] == nil {
            states[entry.id] = installed.contains(entry.filename) ? .installed : .notInstalled
        }
    }

    func state(of entry: ModelEntry) -> ModelState { states[entry.id] ?? .notInstalled }

    var installedCount: Int { states.values.filter { $0 == .installed }.count }

    var missingModels: [ModelEntry] {
        ModelCatalog.models.filter { state(of: $0) == .notInstalled || state(of: $0) == .failed }
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
        states[entry.id] = .downloading(0)
        let destination = modelsDir.appendingPathComponent(entry.filename)
        tasks[entry.id] = Task { [weak self] in
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
                if !Task.isCancelled { self?.states[entry.id] = .failed }
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
