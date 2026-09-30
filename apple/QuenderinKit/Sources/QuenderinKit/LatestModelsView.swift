#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class LatestModelsController: ObservableObject {
    static let shared = LatestModelsController()
    @Published private(set) var snapshot: ModelReleaseSnapshot?
    @Published private(set) var refreshing = false
    private let repository: ModelReleaseRepository?

    init() {
        let data = Bundle.module.url(forResource: "model-releases", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let data, let root {
            repository = try? ModelReleaseRepository(
                cacheURL: root.appendingPathComponent("Quenderin/model-releases.json"), bundledData: data)
            if let feed = try? ModelReleaseFeed.decode(data) {
                snapshot = ModelReleaseSnapshot(feed: feed, saved: true, refreshFailed: false)
            }
        } else { repository = nil }
    }

    func refresh(force: Bool = false) async {
        guard !refreshing, let repository else { return }
        refreshing = true
        defer { refreshing = false }
        snapshot = await repository.current()
        snapshot = await repository.refresh(force: force)
    }
}

/// Shared by the Mac library and the Mac/iPhone picker. Unknown releases can be explored;
/// only hash-matched shipped entries expose the existing, device-gated install action.
struct LatestModelsView: View {
    @ObservedObject private var controller = LatestModelsController.shared
    @Environment(\.colorScheme) private var scheme
    let onSelect: (ModelEntry) -> Void
    @State private var maxGB = 3
    @State private var showAll = false

    var body: some View {
        let p = QuenderinPalette.of(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest model releases").font(.headline).foregroundStyle(p.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    Task { await controller.refresh(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(controller.refreshing)
            }
            Text("Explore new GGUFs. File size is a download estimate; new architectures need compatibility checks before becoming a recommendation.")
                .font(.caption).foregroundStyle(p.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Maximum download", selection: $maxGB) {
                Text("≤ 3 GB").tag(3)
                Text("≤ 6 GB").tag(6)
                Text("All sizes").tag(24)
            }
            .pickerStyle(.segmented)
            if let snapshot = controller.snapshot {
                HStack(spacing: 6) {
                    if controller.refreshing { ProgressView().controlSize(.small) }
                    Text(status(snapshot))
                        .font(.caption2).foregroundStyle(p.onSurfaceVariant)
                }
                let filtered = snapshot.feed.models.filter { $0.downloadGB <= Double(maxGB) }
                let shown = showAll ? filtered : Array(filtered.prefix(3))
                if filtered.isEmpty {
                    Text("No releases within this download size. Try a larger limit.")
                        .font(.caption).foregroundStyle(p.onSurfaceVariant)
                }
                ForEach(shown) { release in
                    releaseRow(release, palette: p)
                }
                if filtered.count > 3 {
                    Button(showAll ? "Show fewer" : "Show all \(filtered.count) releases") { showAll.toggle() }
                        .font(.callout)
                }
            } else {
                Text("The release list is unavailable. Your installed and built-in models are ready below.")
                    .font(.caption).foregroundStyle(p.onSurfaceVariant)
            }
        }
        .padding(14)
        .background(p.surfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.onSurfaceVariant.opacity(0.15), lineWidth: 1))
        .task { await controller.refresh() }
    }

    private func status(_ snapshot: ModelReleaseSnapshot) -> String {
        let date = ModelReleaseFeed.date(snapshot.feed.checkedAt)
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.feed.checkedAt
        let source = snapshot.saved ? "Saved snapshot" : "Checked online"
        let partial = snapshot.feed.partial ? " · partial results" : ""
        let failure = snapshot.refreshFailed ? " · refresh unavailable" : ""
        return "\(source) · \(date)\(partial)\(failure)"
    }

    @ViewBuilder
    private func releaseRow(_ release: ModelRelease, palette p: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(release.name).font(.callout.weight(.semibold)).foregroundStyle(p.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: "%.1f GB · %@ · released %@", release.downloadGB,
                        release.quantization, String(release.createdAt.prefix(10))))
                .font(.caption.monospacedDigit()).foregroundStyle(p.onSurfaceVariant)
            if let entry = release.catalogEntry() {
                let fitness = fitness(entry)
                Text(fitness.canLoad ? "Available in this app · estimated memory fit" : "Available in this app · too large for this device")
                    .font(.caption2).foregroundStyle(fitness.canLoad ? p.statusText : .orange)
                Button("Choose \(entry.label)") { onSelect(entry) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!fitness.canLoad)
            } else {
                Text("Compatibility not tested in this app")
                    .font(.caption2).foregroundStyle(p.onSurfaceVariant)
            }
            Link("Model card and license ↗", destination: release.sourceURL)
                .font(.caption).foregroundStyle(p.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func fitness(_ model: ModelEntry) -> MemoryCheckResult {
        #if os(iOS)
        IPhoneModelSelector.fitness(of: model, for: DeviceProfiler.current())
        #else
        MemoryFitness.check(for: model)
        #endif
    }
}
#endif
