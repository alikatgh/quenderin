import Foundation

/// The registry of models the user brought in from OUTSIDE the curated `ModelCatalog` — today, GGUFs
/// found via the Hugging Face search. `ModelCatalog` is compiled-in and immutable; a searched model is
/// only known at runtime, so its `ModelEntry` must be PERSISTED or the app forgets it on the next launch
/// (`OnboardingModel.start`'s relaunch fast-path resolves the active id through `ModelCatalog.entry(id:)`,
/// which can't know an `hf:` id). This store is that missing half: record the entry when it's downloaded,
/// and resolve it on boot so "Use" survives a relaunch — the file on disk is remembered, not orphaned.
///
/// `ModelEntry` is `Codable`, so this is just a JSON array in UserDefaults. macOS/iOS only (the open
/// search is an Apple-app feature); nothing here touches the cross-platform parity surface.
public final class SideloadedModels: @unchecked Sendable {
    // @unchecked: the only stored state is a `let` UserDefaults, which is itself thread-safe — this
    // type has no mutable state of its own, so shared access across actors is sound (twin of CancelFlag).
    public static let shared = SideloadedModels()

    private let defaultsKey = "quenderin.sideloadedModels"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Every sideloaded entry, in insertion order (newest last).
    public var all: [ModelEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([ModelEntry].self, from: data) else { return [] }
        return entries
    }

    /// Resolve a sideloaded model by id — the boot-path twin of `ModelCatalog.entry(id:)`.
    public func entry(id: String) -> ModelEntry? { all.first { $0.id == id } }

    /// Record (or update) a sideloaded model. De-duplicated by id so re-downloading the same quant
    /// doesn't stack duplicates; the newest definition wins (a size/sha refresh is honoured).
    public func record(_ entry: ModelEntry) {
        var entries = all.filter { $0.id != entry.id }
        entries.append(entry)
        persist(entries)
    }

    /// Forget a sideloaded model (e.g. the user deleted its file). Idempotent.
    public func remove(id: String) {
        persist(all.filter { $0.id != id })
    }

    private func persist(_ entries: [ModelEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
