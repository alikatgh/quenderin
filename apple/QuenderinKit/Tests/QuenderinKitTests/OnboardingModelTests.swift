import XCTest
@testable import QuenderinKit

@MainActor
final class OnboardingModelTests: XCTestCase {

    private func freshModelsDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-onb-\(UUID().uuidString)", isDirectory: true)
    }

    func testStartProbesAndRecommends() async {
        let dir = freshModelsDir()
        let model = OnboardingModel(downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir)

        await model.start()

        guard case let .recommended(entry, hardware, _) = model.phase else {
            return XCTFail("expected .recommended, got \(model.phase)")
        }
        XCTAssertNotNil(ModelCatalog.entry(id: entry.id))
        XCTAssertGreaterThan(hardware.totalRAMGB, 0)
    }

    func testInstallHappyPathReachesReady() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = OnboardingModel(downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir,
                                    availableDiskBytes: { _ in .max })   // host disk must not decide this test
        let entry = ModelCatalog.smallest

        await model.install(entry)

        guard case let .ready(readyEntry) = model.phase else {
            return XCTFail("expected .ready, got \(model.phase)")
        }
        XCTAssertEqual(readyEntry.id, entry.id)
        // The downloader wrote the file to the models dir.
        let expected = dir.appendingPathComponent(entry.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testInstallRemembersModelAndStartRestoresItOnRelaunch() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First launch: install succeeds → the model id is remembered.
        var remembered: String?
        let first = OnboardingModel(
            downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir,
            availableDiskBytes: { _ in .max },
            recallActiveModelID: { nil },
            rememberActiveModelID: { remembered = $0 }
        )
        await first.install(ModelCatalog.smallest)
        guard case .ready = first.phase else { return XCTFail("expected .ready, got \(first.phase)") }
        XCTAssertEqual(remembered, ModelCatalog.smallest.id)

        // "Relaunch": a fresh OnboardingModel that recalls the remembered id must land straight on
        // .ready from start() — never replay the first-run recommendation screen.
        let second = OnboardingModel(
            downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir,
            availableDiskBytes: { _ in .max },
            recallActiveModelID: { remembered },
            rememberActiveModelID: { _ in }
        )
        await second.start()
        guard case let .ready(entry) = second.phase else {
            return XCTFail("expected relaunch to restore straight to .ready, got \(second.phase)")
        }
        XCTAssertEqual(entry.id, ModelCatalog.smallest.id)
    }

    func testInstallSkipsDownloadWhenFileExists() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A genuinely valid stub GGUF (magic header + a pinned sha256 that matches these exact
        // bytes) — install()'s "already exists" fast path now re-verifies integrity (audit: it
        // used to trust bare file presence), so an empty/garbage fixture no longer proves the
        // "skip download" path; it just proves the file gets correctly rejected and re-fetched.
        let payload = ModelIntegrity.ggufMagic + Data(repeating: 0x2A, count: 96)
        let fileURL = dir.appendingPathComponent("stub.gguf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try payload.write(to: fileURL)
        let entry = ModelEntry(
            id: "stub", label: "Stub", filename: "stub.gguf", ramGB: 1, sizeLabel: "100 B",
            paramsBillions: 0.001, quantization: "Q2_K", urlString: "https://example.com/stub.gguf",
            sha256: try ModelIntegrity.sha256Hex(of: fileURL)
        )

        // A downloader that would FAIL if called — proves we skipped it.
        let model = OnboardingModel(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "should not be called")),
            engine: MockInferenceEngine(),
            modelsDir: dir,
            availableDiskBytes: { _ in .max }   // host disk must not decide this test
        )
        await model.install(entry)

        guard case .ready = model.phase else {
            return XCTFail("expected .ready (download skipped), got \(model.phase)")
        }
    }

    func testInstallRejectsAndRefetchesAnInvalidExistingFile() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = ModelCatalog.smallest

        // A pre-existing file that is NOT a valid GGUF (e.g. truncated by a prior crash between
        // moveItem and integrity verification) must be rejected, not trusted, by the "file
        // already exists" fast path.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(entry.filename).path, contents: Data())

        let model = OnboardingModel(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "offline")),
            engine: MockInferenceEngine(),
            modelsDir: dir,
            availableDiskBytes: { _ in .max }   // host disk must not decide this test
        )
        await model.install(entry)

        // The downloader WAS invoked (and failed) — proving the invalid existing file was
        // discarded rather than loaded straight into the engine.
        guard case let .failed(message) = model.phase else {
            return XCTFail("expected .failed after rejecting the invalid existing file, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("offline"), "should have fallen through to a real (failing) download: \(message)")
    }

    func testInstallSurfacesDownloadFailure() async {
        let dir = freshModelsDir()
        let model = OnboardingModel(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "offline")),
            engine: MockInferenceEngine(),
            modelsDir: dir,
            availableDiskBytes: { _ in .max }   // host disk must not decide this test
        )

        await model.install(ModelCatalog.smallest)

        guard case let .failed(message) = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("offline"), "message should explain the cause: \(message)")
    }

    func testStartUsesIPhoneSelectorWhenProfileInjected() async {
        let dir = freshModelsDir()
        let device = IOSDeviceProfile(
            deviceName: "iPhone 15 Pro", identifier: "iPhone16,1", chip: .a17Pro, totalRAMGB: 8,
            appMemoryBudgetGB: AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: 8),
            freeDiskGB: 128, isKnownDevice: true
        )
        let model = OnboardingModel(
            downloader: MockModelDownloader(), engine: MockInferenceEngine(),
            modelsDir: dir, deviceProfile: device
        )

        await model.start()

        guard case let .recommended(entry, _, fitness) = model.phase else {
            return XCTFail("expected .recommended, got \(model.phase)")
        }
        // The jetsam-aware selector picks the safe 4B on an 8 GB iPhone, not a 7B/14B over-pick.
        XCTAssertEqual(entry.id, "qwen3-4b")
        XCTAssertEqual(model.selection?.model.id, "qwen3-4b")
        XCTAssertTrue(fitness.message.contains("iPhone 15 Pro"), "fitness carries the rationale")
        XCTAssertFalse(model.selection?.alternatives.isEmpty ?? true, "alternatives are surfaced")
    }

    func testInstallSurfacesLoadFailure() async {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Mock download succeeds, but the real LlamaEngine (no llama.cpp linked)
        // fails to load → onboarding must surface a clean failure, not crash.
        let model = OnboardingModel(
            downloader: MockModelDownloader(),
            engine: LlamaEngine(),
            modelsDir: dir
        )

        await model.install(ModelCatalog.smallest)

        guard case .failed = model.phase else {
            return XCTFail("expected .failed from LlamaEngine load, got \(model.phase)")
        }
    }

    /// A failed model SWITCH must restore the previously-working model, not leave the engine empty (H1).
    func testFailedSwitchRestoresPreviousModel() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelA = ModelCatalog.smallest
        let modelB = try XCTUnwrap(ModelCatalog.models.first { $0.id != modelA.id })

        let engine = FailOnLoadEngine(failingID: modelB.id)
        // Inject unlimited disk: this test exercises the failed-LOAD restore path with the 9 GB 14B,
        // which the real-disk preflight would otherwise veto on a nearly-full host machine.
        let onboarding = OnboardingModel(
            downloader: MockModelDownloader(), engine: engine, modelsDir: dir,
            availableDiskBytes: { _ in .max }
        )

        await onboarding.install(modelA)                      // first model loads fine
        guard case .ready(let readyA) = onboarding.phase, readyA.id == modelA.id else {
            return XCTFail("expected .ready(modelA), got \(onboarding.phase)")
        }

        await onboarding.install(modelB)                      // switch to B — B fails to load
        guard case .ready(let readyB) = onboarding.phase else {
            return XCTFail("a failed switch must restore the previous model, got \(onboarding.phase)")
        }
        XCTAssertEqual(readyB.id, modelA.id)                  // restored to A — session not bricked
        let loaded = await engine.loadedModelID()
        XCTAssertEqual(loaded, modelA.id)                     // engine actually re-loaded A
    }

    /// A device too small to run even the smallest model fails onboarding honestly — no doomed download.
    func testUnsupportedDeviceFailsOnboarding() async {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiny = IOSDeviceProfile(
            deviceName: "Ancient", identifier: "z", chip: .a12, totalRAMGB: 1,
            appMemoryBudgetGB: 0.2, freeDiskGB: 32, isKnownDevice: false
        )
        let onboarding = OnboardingModel(
            downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir, deviceProfile: tiny
        )
        await onboarding.start()
        guard case .failed = onboarding.phase else {
            return XCTFail("unsupported device must fail onboarding, got \(onboarding.phase)")
        }
    }

    /// A second `install` fired while one is in flight (rapid double-tap / Settings switch during a
    /// download) must be IGNORED, not race `phase` + `engine.load` onto the wrong model. The gated
    /// engine holds install(a) inside `load`, so install(b) is provably concurrent.
    func testConcurrentInstallIsIgnored() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = ModelCatalog.smallest
        let b = ModelCatalog.models.first { $0.id != a.id }!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pre-create both files so install skips download and parks straight in engine.load.
        FileManager.default.createFile(atPath: dir.appendingPathComponent(a.filename).path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent(b.filename).path, contents: Data())

        let engine = GatedLoadEngine()
        let model = OnboardingModel(downloader: MockModelDownloader(), engine: engine, modelsDir: dir,
                                    availableDiskBytes: { _ in .max })   // host disk must not decide this test

        let taskA = Task { await model.install(a) }
        while !model.isInstalling { await Task.yield() }   // install(a) is in flight
        await model.install(b)                              // concurrent → the guard makes this a no-op
        await engine.release()                              // let install(a)'s load complete
        await taskA.value

        let loaded = await engine.loadedModelID()
        XCTAssertEqual(loaded, a.id, "the concurrent second install must be ignored; the first model wins")
        XCTAssertFalse(model.isInstalling)
    }

    func testCancelDuringDownloadReturnsToRecommendation() async throws {
        // Regression: cancelling the CONSUMING task makes AsyncThrowingStream iteration end
        // WITHOUT throwing — install() used to march on into engine.load against a file that was
        // never written and dead-end in .failed("Model file is missing…"). A user cancel must land
        // back on .recommended instead. (Caught live on the macOS client's 9 GB download.)
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = OnboardingModel(downloader: EndlessDownloader(), engine: MockInferenceEngine(), modelsDir: dir,
                                    availableDiskBytes: { _ in .max })   // host disk must not decide this test
        let entry = ModelCatalog.smallest

        model.beginInstall(entry)
        for _ in 0..<200 {                                   // wait for the download to be in flight
            if case .downloading = model.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .downloading = model.phase else {
            return XCTFail("expected .downloading, got \(model.phase)")
        }

        model.cancelInstall()
        for _ in 0..<200 {                                   // the cancel must NOT surface as .failed
            if case .recommended = model.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .recommended = model.phase else {
            return XCTFail("expected .recommended after cancel, got \(model.phase)")
        }
        XCTAssertFalse(model.isInstalling)
    }
}

/// Downloader whose stream yields progress until the consuming task cancels, then ends WITHOUT
/// throwing — the exact shape a real cancelled `AsyncThrowingStream` takes (onTermination stops the
/// URLSession task; iteration just returns nil). Never writes the destination file.
private struct EndlessDownloader: ModelDownloader {
    func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                var fraction = 0.0
                while !Task.isCancelled {
                    continuation.yield(.progress(fraction))
                    fraction = min(0.5, fraction + 0.01)
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()   // ends, no throw — like a real cancelled stream
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// Engine whose `load` blocks until `release()` — lets a test hold an `install` mid-flight and fire a
/// second concurrent `install` to prove the guard serializes them. `release()` before the park is fine.
private actor GatedLoadEngine: InferenceEngine {
    private var loaded: String?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func loadedModelID() async -> String? { loaded }
    func load(model: ModelEntry, at fileURL: URL) async throws {
        if !released { await withCheckedContinuation { waiter = $0 } }
        loaded = model.id
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func unload() async { loaded = nil }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Test engine that loads any model except `failingID`, which throws — exercises the failed-switch
/// recovery path without a real (multi-GB) model.
private actor FailOnLoadEngine: InferenceEngine {
    let failingID: String
    private var loaded: String?
    init(failingID: String) { self.failingID = failingID }
    func loadedModelID() async -> String? { loaded }
    func load(model: ModelEntry, at fileURL: URL) async throws {
        if model.id == failingID { throw InferenceError.loadFailed(reason: "test: too big to load") }
        loaded = model.id
    }
    func unload() async { loaded = nil }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
