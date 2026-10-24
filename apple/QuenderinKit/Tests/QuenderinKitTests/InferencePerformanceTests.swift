import XCTest
@testable import QuenderinKit

final class InferencePerformanceTests: XCTestCase {
    private let now: Int64 = 1_792_800_000_000
    private func sample(_ id: String = "a", decode: Double = 640, time: Int64? = nil,
                        artifact: String? = nil, context: Int = 2048, tokens: Int = 64,
                        thermal: String = "nominal", runtime: String? = nil, load: Double = 0) -> InferencePerformanceSample {
        .init(modelID: id, artifactSHA256: artifact ?? String(repeating: id == "a" ? "1" : "2", count: 64),
              runtimeID: runtime ?? String(repeating: "a", count: 64), backendID: "prism", environmentID: String(repeating: "c", count: 64),
              contextTokens: context, promptTokens: 128, prefillTokens: 128, decodedTokens: tokens,
              prefillMs: 128, decodeMs: decode, firstTokenMs: 130, maxGapMs: 20, loadMs: load,
              cacheMode: "cold", thermalState: thermal, recordedAtMs: time ?? now)
    }
    private func series(_ row: InferencePerformanceSample, count: Int = 3) -> [InferencePerformanceSample] {
        (0..<count).map { index in
            .init(modelID: row.modelID, artifactSHA256: row.artifactSHA256, runtimeID: row.runtimeID,
                backendID: row.backendID, environmentID: row.environmentID, contextTokens: row.contextTokens,
                promptTokens: row.promptTokens, prefillTokens: row.prefillTokens, decodedTokens: row.decodedTokens,
                prefillMs: row.prefillMs, decodeMs: row.decodeMs, firstTokenMs: row.firstTokenMs,
                maxGapMs: row.maxGapMs, loadMs: row.loadMs, cacheMode: row.cacheMode, thermalState: row.thermalState,
                recordedAtMs: row.recordedAtMs - Int64(index))
        }
    }
    private func candidate(_ id: String, runtimeAvailable: Bool = true, fitsMemory: Bool = true) -> AutomaticModelCandidate {
        .init(modelID: id, artifactSHA256: String(repeating: id == "a" ? "1" : "2", count: 64),
              runtimeID: String(repeating: "a", count: 64), backendID: "prism", environmentID: String(repeating: "c", count: 64),
              contextTokens: 2048, runtimeAvailable: runtimeAvailable, fitsMemory: fitsMemory)
    }
    private func choose(_ rows: [InferencePerformanceSample], candidates: [AutomaticModelCandidate]? = nil) -> AutomaticModelDecision? {
        AutomaticModelPolicy.choose(currentID: "a", candidates: candidates ?? [candidate("a"), candidate("b")],
            samples: rows, promptTokens: 128, expectedOutputTokens: 64, nowMs: now)
    }
    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["QUENDERIN_TEST_SCRATCH"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: root).appendingPathComponent("performance-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    func testObservedMedianAndLoadCostNeedTwentyPercentImprovement() {
        let baseline = series(sample())
        XCTAssertEqual(choose(baseline + series(sample("b", decode: 300)))?.modelID, "b")
        XCTAssertEqual(choose(baseline + series(sample("b", decode: 300, load: 500)))?.modelID, "a")
        XCTAssertEqual(choose(baseline + series(sample("b", decode: 550)))?.modelID, "a")
        // An outlier cannot outweigh the median of comparable samples.
        XCTAssertEqual(choose(baseline + [sample("b", decode: 300), sample("b", decode: 300, time: now - 1), sample("b", decode: 60_000, time: now - 2)])?.modelID, "b")
    }
    func testUnknownCurrentAndMissingSamplesKeepViableCurrent() {
        let fast = series(sample("b", decode: 40))
        XCTAssertEqual(choose(fast)?.modelID, "a")
        XCTAssertEqual(choose(fast)?.observed, false)
        XCTAssertEqual(choose(series(sample()) + series(sample("b", decode: 40), count: 2))?.modelID, "a")
    }
    func testArtifactRuntimeContextThermalAndMinimumTokensInvalidateEvidence() {
        let baseline = series(sample())
        for incompatible in [sample("b", decode: 40, artifact: String(repeating: "3", count: 64)),
                             sample("b", decode: 40, context: 4096), sample("b", decode: 40, tokens: 31),
                             sample("b", decode: 40, thermal: "serious"), sample("b", decode: 40, runtime: String(repeating: "d", count: 64)),
                             sample("b", decode: 40, time: now - 31 * 86_400_000)] {
            XCTAssertEqual(choose(baseline + series(incompatible))?.modelID, "a")
        }
    }
    func testReplayedSingleReportCannotSupplyThreeIndependentSamples() {
        let baseline = series(sample())
        XCTAssertEqual(choose(baseline + Array(repeating: sample("b", decode: 40), count: 3))?.modelID, "a")
    }
    func testFastRecordCannotEnableUnavailableRuntimeOrOverrideMemory() {
        let rows = series(sample()) + series(sample("b", decode: 1))
        XCTAssertEqual(choose(rows, candidates: [candidate("a"), candidate("b", runtimeAvailable: false)])?.modelID, "a")
        XCTAssertEqual(choose(rows, candidates: [candidate("a"), candidate("b", fitsMemory: false)])?.modelID, "a")
    }
    func testAtomicStoreBoundsAndRejectsContentFreeInvalidNumbers() async throws {
        let file = try directory().appendingPathComponent("observations.json")
        let store = InferencePerformanceStore(file: file)
        for n in 0..<80 {
            let recorded = await store.record(sample(time: now - Int64(80 - n)), nowMs: now)
            XCTAssertTrue(recorded)
        }
        let saved = await store.samples(nowMs: now)
        XCTAssertEqual(saved.count, 64)
        let bytes = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(bytes.count, InferencePerformanceStore.maximumBytes)
        let keys = Set(try XCTUnwrap((JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])?.first).keys)
        XCTAssertEqual(keys, Set(["modelID", "artifactSHA256", "runtimeID", "backendID", "environmentID", "contextTokens", "promptTokens", "prefillTokens", "decodedTokens", "prefillMs", "decodeMs", "firstTokenMs", "maxGapMs", "loadMs", "cacheMode", "thermalState", "recordedAtMs"]))
        let bad = await store.record(sample(decode: .infinity), nowMs: now)
        XCTAssertFalse(bad)
        let short = await store.record(sample(tokens: 31), nowMs: now)
        XCTAssertFalse(short)
        let stale = await store.record(sample(time: now - 31 * 86_400_000), nowMs: now)
        XCTAssertFalse(stale)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testFailedAtomicWritePreservesPriorStoreAndCorruptionFallsBack() async throws {
        let file = try directory().appendingPathComponent("observations.json")
        let normal = InferencePerformanceStore(file: file)
        _ = await normal.record(sample(), nowMs: now)
        let previous = try Data(contentsOf: file)
        let failing = InferencePerformanceStore(file: file, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let accepted = await failing.record(sample("b"), nowMs: now)
        XCTAssertFalse(accepted)
        XCTAssertEqual(try Data(contentsOf: file), previous)
        let surviving = await failing.samples(nowMs: now)
        XCTAssertEqual(surviving.count, 1)
        try Data(repeating: 32, count: InferencePerformanceStore.maximumBytes + 1).write(to: file)
        let oversized = await normal.samples(nowMs: now)
        XCTAssertTrue(oversized.isEmpty)
        try Data("broken".utf8).write(to: file)
        let corrupt = await normal.samples(nowMs: now)
        XCTAssertTrue(corrupt.isEmpty)
    }
    func testUnknownArtifactCannotProduceUsableIdentity() {
        let unpinned = ModelEntry(id: "unknown", label: "Unknown", filename: "model.gguf", ramGB: 1,
            sizeLabel: "1 GB", paramsBillions: 1, quantization: "Q4_K_M", urlString: "", sha256: nil)
        XCTAssertNil(InferencePerformanceIdentity.artifact(unpinned))
    }
    func testSharedPerformancePolicyFixtures() throws {
        struct Fixtures: Decodable { let cases: [Case] }
        struct Candidate: Decodable {
            let modelID: String; let artifactSHA256: String; let runtimeID: String; let backendID: String; let environmentID: String
            let installed: Bool; let verified: Bool; let runtimeAvailable: Bool; let fitsMemory: Bool
            let fitsContext: Bool; let fitsDisk: Bool; let supportsTask: Bool; let qualityEligible: Bool; let cacheMode: String?
            func value(context: Int) -> AutomaticModelCandidate {
                .init(modelID: modelID, artifactSHA256: artifactSHA256, runtimeID: runtimeID, backendID: backendID,
                    environmentID: environmentID, contextTokens: context, installed: installed, verified: verified,
                    runtimeAvailable: runtimeAvailable, fitsMemory: fitsMemory, fitsContext: fitsContext,
                    fitsDisk: fitsDisk, supportsTask: supportsTask, qualityEligible: qualityEligible, cacheMode: cacheMode)
            }
        }
        struct Case: Decodable {
            let name: String; let currentID: String?; let promptTokens: Int; let expectedOutputTokens: Int
            let contextTokens: Int; let cacheMode: String; let nowMs: Int64; let candidates: [Candidate]
            let samples: [InferencePerformanceSample]; let expectedModelID: String?; let expectedObserved: Bool?
        }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/inference-performance-fixtures.json")
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: file))
        XCTAssertGreaterThanOrEqual(fixtures.cases.count, 10)
        for f in fixtures.cases {
            let result = AutomaticModelPolicy.choose(currentID: f.currentID, candidates: f.candidates.map { $0.value(context: f.contextTokens) },
                samples: f.samples, promptTokens: f.promptTokens, expectedOutputTokens: f.expectedOutputTokens,
                cacheMode: f.cacheMode, nowMs: f.nowMs)
            XCTAssertEqual(result?.modelID, f.expectedModelID, f.name)
            if let expected = f.expectedObserved { XCTAssertEqual(result?.observed, expected, f.name) }
            if result?.modelID == f.expectedModelID && (f.expectedObserved == nil || result?.observed == f.expectedObserved) { emitFixturePass("INFERENCE_PERFORMANCE_FIXTURE_PASS " + f.name) }
        }
    }
}
