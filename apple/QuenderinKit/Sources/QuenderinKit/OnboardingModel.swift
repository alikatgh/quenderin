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

    public init(downloader: ModelDownloader, engine: InferenceEngine, modelsDir: URL? = nil) {
        self.downloader = downloader
        self.engine = engine
        self.modelsDir = modelsDir ?? Self.defaultModelsDir()
    }

    /// Probe hardware and produce a recommendation. Idempotent.
    public func start() async {
        phase = .probing
        let hardware = HardwareProbe.current()
        let model = ModelRecommender.recommendedModel(forTotalRAMGB: hardware.totalRAMGB)
        let fitness = MemoryFitness.check(for: model)
        phase = .recommended(model, hardware, fitness)
    }

    /// Download (if needed) then load `model`, driving `phase` through the flow.
    public func install(_ model: ModelEntry) async {
        let destination = modelsDir.appendingPathComponent(model.filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            await load(model, at: destination)
            return
        }

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

        await load(model, at: destination)
    }

    private func load(_ model: ModelEntry, at url: URL) async {
        phase = .loading(model)
        do {
            try await engine.load(model: model, at: url)
            phase = .ready(model)
        } catch {
            phase = .failed(Self.describe(error))
        }
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
