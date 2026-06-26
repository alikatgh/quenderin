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

    public init(
        downloader: ModelDownloader,
        engine: InferenceEngine,
        modelsDir: URL? = nil,
        deviceProfile: IOSDeviceProfile? = nil
    ) {
        self.downloader = downloader
        self.engine = engine
        self.modelsDir = modelsDir ?? Self.defaultModelsDir()
        self.deviceProfile = deviceProfile
    }

    /// Probe hardware and produce a recommendation. Idempotent.
    ///
    /// On iPhones (or when a profile is injected) this uses the jetsam-budget- and
    /// chip-aware `IPhoneModelSelector` and records the full `selection` so the UI can
    /// explain the choice. Elsewhere it uses the shared RAM-band recommender.
    public func start() async {
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
            let model = ModelRecommender.recommendedModel(forTotalRAMGB: hardware.totalRAMGB)
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

    /// Download (if needed) then load `model`, driving `phase` through the flow. On a model SWITCH
    /// whose new model fails to load, the previously-working model is restored (H1).
    public func install(_ model: ModelEntry) async {
        guard !isInstalling else { return }   // serialize: a concurrent install would race phase + engine.load
        isInstalling = true
        defer { isInstalling = false }

        // The model we fall back to if this one fails to load — `nil` on first-run onboarding.
        let previousID = await engine.loadedModelID()
        let destination = modelsDir.appendingPathComponent(model.filename)

        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let url = model.downloadURL else {
                phase = .failed("\(model.label) has no valid download URL.")
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
                phase = .failed(Self.describe(error))
                return
            }
        }

        phase = .loading(model)
        do {
            try await engine.load(model: model, at: destination)
            phase = .ready(model)
        } catch {
            // `load()` already freed the previously-loaded model before failing, so on a failed
            // switch restore the prior model rather than leaving the engine empty (H1).
            if let previousID, previousID != model.id,
               let previous = ModelCatalog.entry(id: previousID),
               await restore(previous) {
                phase = .ready(previous)
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
