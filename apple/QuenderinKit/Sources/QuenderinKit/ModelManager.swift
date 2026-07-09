import Foundation

/// A model that is downloaded and present on disk: its catalog entry, on-disk size, and
/// whether it's the active (loaded) one.
public struct InstalledModel: Identifiable {
    public let model: ModelEntry
    public let sizeBytes: Int64
    public let isActive: Bool
    public var id: String { model.id }
}

/// The filesystem behind `ModelManager` — which model files exist, their sizes, and how to
/// delete one. Abstracted so the manager is pure and testable; the app supplies a
/// FileManager-backed implementation over the models directory, tests use
/// `InMemoryModelStorage`.
public protocol ModelStorage: AnyObject {
    func installedFilenames() -> [String]
    func sizeBytes(of filename: String) -> Int64
    func delete(_ filename: String)
}

/// In-memory model storage for tests and previews.
public final class InMemoryModelStorage: ModelStorage {
    private var files: [String: Int64]
    public init(_ files: [String: Int64] = [:]) { self.files = files }
    public func install(_ filename: String, sizeBytes: Int64) { files[filename] = sizeBytes }
    public func installedFilenames() -> [String] { Array(files.keys) }
    public func sizeBytes(of filename: String) -> Int64 { files[filename] ?? 0 }
    public func delete(_ filename: String) { files[filename] = nil }
}

/// Real `ModelStorage` over the on-disk models directory (the same dir the downloader writes to and
/// `OnboardingModel` loads from). This is the impl the app uses to drive `ModelManager` — without it
/// the manager could only run against the in-memory test double. Pure FileManager calls, so it's
/// unit-testable against a temp directory. Twin of Android `FileModelStorage`.
///
/// `extraSearchDirs` lists older install locations (Application Support) so models downloaded
/// before the `~/.quenderin/models` unification still show as installed without a migration.
public final class FileManagerModelStorage: ModelStorage {
    private let directory: URL
    private let extraSearchDirs: [URL]
    private let fileManager: FileManager

    public init(directory: URL, extraSearchDirs: [URL] = [], fileManager: FileManager = .default) {
        self.directory = directory
        self.extraSearchDirs = extraSearchDirs
        self.fileManager = fileManager
    }

    /// Primary + legacy dirs (primary first). Used by installs that still live in App Support.
    private var allDirs: [URL] {
        [directory] + extraSearchDirs.filter { $0.path != directory.path }
    }

    public func installedFilenames() -> [String] {
        var names = Set<String>()
        for dir in allDirs {
            let urls = (try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false {
                names.insert(url.lastPathComponent)
            }
        }
        return Array(names)
    }

    public func sizeBytes(of filename: String) -> Int64 {
        for dir in allDirs {
            let url = dir.appendingPathComponent(filename)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                return Int64(size)
            }
        }
        return 0
    }

    public func delete(_ filename: String) {
        for dir in allDirs {
            try? fileManager.removeItem(at: dir.appendingPathComponent(filename))
        }
    }

    /// Resolve a filename to the first existing URL across primary + legacy dirs (load path).
    public func url(for filename: String) -> URL? {
        for dir in allDirs {
            let url = dir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Manages the set of on-device models: which are installed, which is active, how much disk
/// they use, switching the active one, and deleting one to reclaim space — a real constraint
/// on a phone with several multi-GB models. Pure logic over a `ModelStorage` seam + the
/// catalog, so it unit-tests with no real files. Twin of Kotlin `ModelManager`. (Loading the
/// active model into the engine stays in the app; this owns *what's on disk*, not inference.)
public final class ModelManager {
    private let storage: ModelStorage
    public private(set) var activeModelID: String?

    public init(storage: ModelStorage, activeModelID: String? = nil) {
        self.storage = storage
        self.activeModelID = activeModelID
    }

    /// Installed catalog models — active first, then largest first, then by id for stability.
    public func installed() -> [InstalledModel] {
        let present = Set(storage.installedFilenames())
        return ModelCatalog.models
            .filter { present.contains($0.filename) }
            .map { InstalledModel(model: $0, sizeBytes: storage.sizeBytes(of: $0.filename), isActive: $0.id == activeModelID) }
            .sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.id < $1.id
            }
    }

    public func isInstalled(_ id: String) -> Bool {
        guard let entry = ModelCatalog.entry(id: id) else { return false }
        return storage.installedFilenames().contains(entry.filename)
    }

    /// Total bytes used by all installed models.
    public var totalBytesUsed: Int64 { installed().reduce(0) { $0 + $1.sizeBytes } }

    /// Bytes freeable without touching the active model.
    public var reclaimableBytes: Int64 {
        installed().filter { !$0.isActive }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Make an installed model the active one. No-op returning false if it isn't installed.
    @discardableResult
    public func setActive(_ id: String) -> Bool {
        guard isInstalled(id) else { return false }
        activeModelID = id
        return true
    }

    /// Delete a model's file to reclaim space; returns bytes reclaimed. Deleting the active
    /// model clears `activeModelID` (the app must load another). 0 if it isn't installed.
    @discardableResult
    public func delete(_ id: String) -> Int64 {
        guard let entry = ModelCatalog.entry(id: id), isInstalled(id) else { return 0 }
        let freed = storage.sizeBytes(of: entry.filename)
        storage.delete(entry.filename)
        if activeModelID == id { activeModelID = nil }
        return freed
    }
}
