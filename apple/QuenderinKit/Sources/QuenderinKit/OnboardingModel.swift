import Foundation
import Combine

/// The phases a first-run device moves through. This is the M1 spine.
public enum OnboardingPhase: Sendable, Equatable {
    case probing
    case recommended(ModelEntry, HardwareProfile, MemoryCheckResult)
    case downloading(ModelEntry, progress: Double)
    case loading(ModelEntry)
    case ready(ModelEntry)
    case failed(String)
}

/// Orchestrates "download → ready": probe the device, recommend a model,
/// download it (if not already present), then load it into the inference engine.
///
/// Depends only on the `ModelDownloader` and `InferenceEngine` seams, so the
/// whole flow is unit-testable with mocks — and the app swaps in
/// `URLSessionModelDownloader` + `LlamaEngine` with no other changes.
@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public private(set) var phase: OnboardingPhase = .probing

    private let downloader: ModelDownloader
    private let engine: InferenceEngine
    private let modelsDir: URL
    private let deviceProfile: IOSDeviceProfile?

    /// The full, explained iPhone selection (rationale + alternatives) when the pick
    /// came from `IPhoneModelSelector`. Nil on platforms that use the RAM-band path.
    @Published public private(set) var selection: ModelSelection?

    /// True while an `install` is in flight. Guards against a second concurrent install (a rapid
    /// double-tap, or a Settings model-switch during a download) racing `phase` + `engine.load` and
    /// landing on the wrong model. The UI can also bind this to disable the install/switch control.
    @Published public private(set) var isInstalling = false

    /// The in-flight install, kept so `cancelInstall()` can abort a multi-GB download the user
    /// regrets (wrong model, metered bandwidth, not enough disk).
    private var installTask: Task<Void, Never>?

    /// Free-bytes source for the download preflight. Injectable so tests are deterministic —
    /// without this, any test that installs a big model silently depends on the HOST machine's
    /// live free disk (they started failing on a nearly-full Mac). Defaults to the real volume.
    private let availableDiskBytes: (URL) -> Int64

    /// Persistence of the last successfully-loaded model id across launches (UserDefaults by
    /// default; injectable for tests). Without it, every cold launch replayed first-run
    /// onboarding even though the model was sitting on disk — the app forgot your model.
    private let recallActiveModelID: () -> String?
    private let rememberActiveModelID: (String?) -> Void
    static let activeModelDefaultsKey = "quenderin.activeModelID"

    public init(
        downloader: ModelDownloader,
        engine: InferenceEngine,
        modelsDir: URL? = nil,
        deviceProfile: IOSDeviceProfile? = nil,
        availableDiskBytes: ((URL) -> Int64)? = nil,
        recallActiveModelID: (() -> String?)? = nil,
        rememberActiveModelID: ((String?) -> Void)? = nil
    ) {
        self.downloader = downloader
        self.engine = engine
        self.modelsDir = modelsDir ?? Self.defaultModelsDir()
        self.deviceProfile = deviceProfile
        self.availableDiskBytes = availableDiskBytes ?? { DiskSpace.availableBytes(at: $0) }
        self.recallActiveModelID = recallActiveModelID
            ?? { UserDefaults.standard.string(forKey: Self.activeModelDefaultsKey) }
        self.rememberActiveModelID = rememberActiveModelID
            ?? { UserDefaults.standard.set($0, forKey: Self.activeModelDefaultsKey) }
    }

    /// Probe hardware and produce a recommendation. Idempotent.
    ///
    /// On iPhones (or when a profile is injected) this uses the jetsam-budget- and
    /// chip-aware `IPhoneModelSelector` and records the full `selection` so the UI can
    /// explain the choice. Elsewhere it uses the shared RAM-band recommender.
    public func start() async {
        // Relaunch fast-path: a model that loaded successfully before, and whose file is still on
        // disk, goes straight back to .ready — no first-run onboarding replay. Only from the
        // pristine .probing phase (an explicit "Back to model choice" must show the choice), and
        // install() re-runs the integrity gate before trusting the file, so a corrupted leftover
        // still falls through to a fresh recommendation below.
        if case .probing = phase, let id = recallActiveModelID(),
           let remembered = ModelCatalog.entry(id: id),
           FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(remembered.filename).path) {
            await install(remembered)
            if case .ready = phase { return }
        }
        phase = .probing
        let hardware = HardwareProbe.current()
        if let profile = deviceProfile ?? Self.liveProfile() {
            let sel = IPhoneModelSelector.select(for: profile)
            selection = sel
            if sel.confidence == .unsupported {
                // Even the smallest model can't run here — fail honestly, don't push a doomed download.
                phase = .failed(sel.rationale)
            } else {
                let fitness = MemoryCheckResult(
                    canLoad: true,
                    severity: sel.confidence == .comfortable ? .safe : (sel.confidence == .tight ? .warning : .critical),
                    availableMemoryGB: sel.usableMemoryGB,
                    requiredMemoryGB: sel.estimatedRuntimeGB,
                    remainingAfterLoadGB: sel.memoryHeadroomGB,
                    message: sel.rationale
                )
                phase = .recommended(sel.model, hardware, fitness)
            }
        } else {
            // Fitness-aware, not just the RAM band: the band can pick a model the memory gate
            // then blocks (16 GB Mac → 14B → 89% > the 85% budget), which would put a dead
            // "recommended" model on the first screen. Offer the largest model that loads.
            let model = ModelRecommender.bestInstallableModel(forTotalRAMGB: hardware.totalRAMGB)
            phase = .recommended(model, hardware, MemoryFitness.check(for: model))
        }
    }

    /// The live device profile on iOS; nil elsewhere (desktop/tests fall back to the band).
    static func liveProfile() -> IOSDeviceProfile? {
        #if os(iOS)
        return DeviceProfiler.current()
        #else
        return nil
        #endif
    }

    /// Fire-and-track wrapper around [install]: runs it in a stored Task so `cancelInstall()` can
    /// abort it mid-download. The UI's entry point (onboarding buttons, Settings model switch).
    public func beginInstall(_ model: ModelEntry) {
        guard !isInstalling else { return }
        installTask = Task { await install(model) }
    }

    /// Abort an in-flight install. A cancelled DOWNLOAD returns to the recommendation screen
    /// (nothing was committed; a partial file is re-verified and discarded on the next attempt) —
    /// it is NOT surfaced as a failure.
    public func cancelInstall() {
        installTask?.cancel()
    }

    /// Will this model's download fit on the volume that holds our models? Exposed for the UI so
    /// "not enough space" shows BEFORE a doomed multi-GB download starts, not at 95%.
    public func storageCheck(for model: ModelEntry) -> StorageCheckResult {
        DiskSpace.check(model: model, availableBytes: availableDiskBytes(modelsDir))
    }

    /// Download (if needed) then load `model`, driving `phase` through the flow. On a model SWITCH
    /// whose new model fails to load, the previously-working model is restored (H1).
    public func install(_ model: ModelEntry) async {
        guard !isInstalling else { return }   // serialize: a concurrent install would race phase + engine.load
        isInstalling = true
        defer { isInstalling = false }

        // The model we fall back to if this one fails to load — `nil` on first-run onboarding.
        let previousID = await engine.loadedModelID()
        let destination = modelsDir.appendingPathComponent(model.filename)

        // A file already at `destination` might be a fully-verified completed download — or it might
        // be one that was moved into place but never made it through ModelIntegrity.verify because the
        // process was killed in the crash window between the move and the (multi-GB, non-instant)
        // SHA-256 check. Re-run the same C3 gate the fresh-download path enforces before trusting it;
        // on failure, delete and fall through to a real download rather than loading unverified bytes.
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? ModelIntegrity.verify(fileURL: destination, expectedSHA256: model.sha256)) == nil {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let url = model.downloadURL else {
                phase = .failed("\(model.label) has no valid download URL.")
                return
            }
            // Disk preflight: refuse to START a download that cannot finish — a 9 GB pull that
            // dies at 95% full is exactly the failure DiskSpace exists to prevent.
            let storage = storageCheck(for: model)
            guard storage.hasRoom else {
                phase = .failed(storage.message)
                return
            }
            phase = .downloading(model, progress: 0)
            do {
                // Consumed sequentially on the main actor → ordered phase updates.
                for try await event in downloader.download(from: url, to: destination) {
                    switch event {
                    case .progress(let fraction):
                        phase = .downloading(model, progress: fraction)
                    case .finished:
                        break
                    }
                }
            } catch {
                // A user cancel is a change of mind, not a failure: return to the recommendation
                // screen (start() is idempotent). The partial file is re-verified — and discarded —
                // by the integrity gate on the next install attempt.
                if error is CancellationError || Task.isCancelled {
                    await start()
                } else if case DownloadError.cancelled = error {
                    await start()
                } else {
                    phase = .failed(Self.describe(error))
                }
                return
            }
            // When the CONSUMING task is cancelled, AsyncThrowingStream iteration ends WITHOUT
            // throwing (onTermination cancels the URLSession task) — so a cancelled download can
            // reach here with no file on disk. Don't march into engine.load on a missing file;
            // treat it as the cancel it is.
            if Task.isCancelled || !FileManager.default.fileExists(atPath: destination.path) {
                await start()
                return
            }
        }

        phase = .loading(model)
        do {
            try await engine.load(model: model, at: destination)
            phase = .ready(model)
            rememberActiveModelID(model.id)   // next cold launch restores this model directly
        } catch {
            // `load()` already freed the previously-loaded model before failing, so on a failed
            // switch restore the prior model rather than leaving the engine empty (H1).
            if let previousID, previousID != model.id,
               let previous = ModelCatalog.entry(id: previousID),
               await restore(previous) {
                phase = .ready(previous)
                rememberActiveModelID(previous.id)
            } else {
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// Best-effort reload of a previously-working model after a failed switch (its file is still on
    /// disk). Returns true on success.
    private func restore(_ model: ModelEntry) async -> Bool {
        let destination = modelsDir.appendingPathComponent(model.filename)
        do { try await engine.load(model: model, at: destination); return true }
        catch { return false }
    }

    // MARK: - Helpers

    static func defaultModelsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Quenderin/models", isDirectory: true)
    }

    /// Turn a thrown error into a user-facing message.
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as DownloadError:
            switch error {
            case .invalidURL: return "The model download link is invalid."
            case .writeFailed(let reason): return "Couldn't save the model: \(reason)"
            case .transport(let reason): return "Download failed: \(reason)"
            case .cancelled: return "Download cancelled."
            }
        case let error as InferenceError:
            switch error {
            case .modelNotLoaded: return "No model is loaded yet."
            case .modelFileMissing(let path): return "Model file is missing at \(path)."
            case .loadFailed(let reason): return "Couldn't load the model: \(reason)"
            case .generationFailed(let reason): return "Generation failed: \(reason)"
            case .cancelled: return "Cancelled."
            case .timedOut(let seconds): return "Timed out after \(seconds)s."
            }
        default:
            return error.localizedDescription
        }
    }
}
