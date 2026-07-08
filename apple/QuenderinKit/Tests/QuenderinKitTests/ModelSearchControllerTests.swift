import XCTest
@testable import QuenderinKit

/// The open-catalog search state machine, over a canned provider — no live Hugging Face call.
final class ModelSearchControllerTests: XCTestCase {

    private struct FakeProvider: ModelSearchProviding {
        var hits: [HFModelHit] = []
        var quantsByRepo: [String: [HFQuant]] = [:]
        var fail = false
        func search(_ query: String) async throws -> [HFModelHit] {
            if fail { throw URLError(.notConnectedToInternet) }
            return hits
        }
        func quants(in repo: String) async throws -> [HFQuant] {
            if fail { throw URLError(.notConnectedToInternet) }
            return quantsByRepo[repo] ?? []
        }
    }

    /// Poll the MainActor until `cond` holds or we time out — the search runs in a detached Task.
    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async {
        let start = Date()
        while !cond() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    @MainActor
    func testUnderTwoCharsStaysIdleAndNeverCalls() async {
        let c = ModelSearchController(provider: FakeProvider(hits: [HFModelHit(id: "a/b", downloads: 1, gated: false)]),
                                      debounceNanos: 0)
        c.search("q")
        XCTAssertEqual(c.phase, .idle, "a single character must not fire a search")
    }

    @MainActor
    func testResultsPopulateOnAMatch() async {
        let hits = [HFModelHit(id: "bartowski/Qwen3-4B-GGUF", downloads: 12000, gated: false)]
        let c = ModelSearchController(provider: FakeProvider(hits: hits), debounceNanos: 0)
        c.search("qwen3")
        await waitUntil { if case .results = c.phase { return true }; return false }
        XCTAssertEqual(c.phase, .results(hits))
    }

    @MainActor
    func testNoMatchesIsEmptyNotError() async {
        let c = ModelSearchController(provider: FakeProvider(hits: []), debounceNanos: 0)
        c.search("zznotamodel")
        await waitUntil { c.phase == .empty }
        XCTAssertEqual(c.phase, .empty, "a successful search with 0 hits is empty, distinct from an error")
    }

    @MainActor
    func testNetworkFailureSurfacesAnError() async {
        let c = ModelSearchController(provider: FakeProvider(fail: true), debounceNanos: 0)
        c.search("qwen")
        await waitUntil { if case .error = c.phase { return true }; return false }
        guard case .error = c.phase else { return XCTFail("a failed call must surface an error phase") }
    }

    @MainActor
    func testLoadQuantsSortsSmallestFirstAndCaches() async {
        let repo = "acme/Model-GGUF"
        let big = HFQuant(repo: repo, filename: "m-Q8_0.gguf", sizeBytes: 8_000_000_000, sha256: "a")
        let small = HFQuant(repo: repo, filename: "m-Q4_K_M.gguf", sizeBytes: 4_000_000_000, sha256: "b")
        let c = ModelSearchController(provider: FakeProvider(quantsByRepo: [repo: [big, small]]), debounceNanos: 0)
        c.loadQuants(for: repo)
        await waitUntil { if case .loaded = c.quants[repo] { return true }; return false }
        guard case .loaded(let qs) = c.quants[repo] else { return XCTFail("quants should load") }
        XCTAssertEqual(qs.map(\.filename), ["m-Q4_K_M.gguf", "m-Q8_0.gguf"], "smallest (most-runnable) first")
    }

    @MainActor
    func testClearResetsEverything() async {
        let hits = [HFModelHit(id: "a/b-GGUF", downloads: 1, gated: false)]
        let c = ModelSearchController(provider: FakeProvider(hits: hits), debounceNanos: 0)
        c.search("model")
        await waitUntil { if case .results = c.phase { return true }; return false }
        c.clear()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.query, "")
        XCTAssertTrue(c.quants.isEmpty)
    }
}
