import XCTest
@testable import QuenderinKit

/// Covers the parallel downloader: the pure segment arithmetic, the end-to-end fan-out against a
/// range-honoring `URLProtocol` stub (asserting more than one connection is actually used and the
/// assembled file is byte-exact), and the single-stream fallback when the server ignores ranges.
final class ParallelRangeDownloaderTests: XCTestCase {

    // MARK: - Pure segment plan

    func testSegmentPlanCoversTheFileExactly() {
        for (total, n) in [(Int64(100), 3), (Int64(1000), 7), (Int64(10), 10), (Int64(5), 99)] {
            let plan = DownloadSegments(totalBytes: total, segmentCount: n)
            XCTAssertEqual(plan.segments.first?.start, 0)
            XCTAssertEqual(plan.segments.last?.end, total - 1)
            var expectedStart: Int64 = 0
            for seg in plan.segments {
                XCTAssertEqual(seg.start, expectedStart, "segments must be contiguous")
                XCTAssertLessThanOrEqual(seg.start, seg.end)
                expectedStart = seg.end + 1
            }
            XCTAssertEqual(expectedStart, total, "segments must cover exactly [0, total)")
        }
    }

    func testSegmentCountNeverExceedsBytes() {
        let plan = DownloadSegments(totalBytes: 3, segmentCount: 10)
        XCTAssertEqual(plan.segments.count, 3)
    }

    func testConnectionCountScalesCapsAndBacksOffOnCellular() {
        let big = Int64(4_000_000_000)          // 4 GB
        XCTAssertEqual(DownloadSegments.connectionCount(totalBytes: big, isCellular: false, max: 6), 6)
        XCTAssertEqual(DownloadSegments.connectionCount(totalBytes: big, isCellular: true, max: 6), 3)
        // Small files don't fan out pointlessly (one segment per ~32 MB).
        XCTAssertEqual(DownloadSegments.connectionCount(totalBytes: 5_000_000, isCellular: false, max: 6), 1)
        XCTAssertEqual(DownloadSegments.connectionCount(totalBytes: 70_000_000, isCellular: false, max: 6), 3)
        XCTAssertEqual(DownloadSegments.connectionCount(totalBytes: 0, isCellular: false), 1)
    }

    func testFractionIsCappedAtOne() {
        let plan = DownloadSegments(totalBytes: 100, segmentCount: 2)   // 50 + 50
        XCTAssertEqual(plan.fraction(downloadedPerSegment: [0, 0]), 0, accuracy: 0.0001)
        XCTAssertEqual(plan.fraction(downloadedPerSegment: [50, 50]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(plan.fraction(downloadedPerSegment: [25, 0]), 0.25, accuracy: 0.0001)
        // Over-reporting a segment can't push progress past 1.0.
        XCTAssertEqual(plan.fraction(downloadedPerSegment: [999, 999]), 1.0, accuracy: 0.0001)
    }

    // MARK: - End to end

    func testParallelDownloadUsesMultipleConnectionsAndAssemblesTheFile() async throws {
        // >32 MB forces the planner to open more than one connection (1 per ~32 MB).
        var body = Data([0x47, 0x47, 0x55, 0x46])          // "GGUF" magic for the integrity gate
        body.append(Data(repeating: 0xAB, count: 34_000_000))
        RangeStubURLProtocol.reset(body: body, honorRanges: true)

        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        var progresses: [Double] = []
        var finished: URL?
        for try await event in makeDownloader().download(from: URL(string: "https://example.com/m.gguf")!, to: destination) {
            switch event {
            case .progress(let f): progresses.append(f)
            case .finished(let u): finished = u
            }
        }

        XCTAssertEqual(finished, destination)
        XCTAssertEqual(progresses, progresses.sorted(), "progress must be monotonic")
        XCTAssertEqual(try XCTUnwrap(progresses.last), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: destination), body, "assembled bytes must match the source exactly")
        XCTAssertGreaterThanOrEqual(RangeStubURLProtocol.rangeRequestCount, 2,
                                    "a 34 MB file must be fetched over more than one connection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    func testFallsBackToSingleStreamWhenServerIgnoresRanges() async throws {
        var body = Data([0x47, 0x47, 0x55, 0x46])
        body.append(Data(repeating: 0xCD, count: 8192))
        RangeStubURLProtocol.reset(body: body, honorRanges: false)   // answers 200 to the probe

        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        var finished: URL?
        for try await event in makeDownloader().download(from: URL(string: "https://example.com/m.gguf")!, to: destination) {
            if case .finished(let u) = event { finished = u }
        }
        XCTAssertEqual(finished, destination, "must still succeed via the single-stream fallback")
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    // MARK: - Helpers

    private func makeDownloader() -> ParallelRangeDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeStubURLProtocol.self]
        return ParallelRangeDownloader(session: URLSession(configuration: config), maxConnections: 6)
    }

    private func tempDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-parallel-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model.gguf")
    }
}

/// `URLProtocol` stub that honors `Range:` (206 + Content-Range + the exact slice) or, when
/// `honorRanges` is false, ignores it and returns the whole body as 200 (the fallback case).
/// Records every request so a test can assert the downloader actually fanned out.
private final class RangeStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var honorRanges = true
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _rangeRequestCount = 0
    static var rangeRequestCount: Int { lock.lock(); defer { lock.unlock() }; return _rangeRequestCount }

    static func reset(body: Data, honorRanges: Bool) {
        self.body = body
        self.honorRanges = honorRanges
        lock.lock(); _rangeRequestCount = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client = client else { return }
        let full = Self.body
        let rangeHeader = request.value(forHTTPHeaderField: "Range")

        if Self.honorRanges, let rangeHeader, let (start, end) = Self.parseRange(rangeHeader, total: Int64(full.count)) {
            Self.lock.lock(); Self._rangeRequestCount += 1; Self.lock.unlock()
            let slice = full.subdata(in: Int(start)..<Int(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(slice.count),
                    "Content-Range": "bytes \(start)-\(end)/\(full.count)",
                    "Accept-Ranges": "bytes",
                ])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: slice)
        } else {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(full.count)])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: full)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    /// `bytes=start-end` → `(start, end)`, clamped to the body. `bytes=start-` → to the end.
    static func parseRange(_ value: String, total: Int64) -> (Int64, Int64)? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startStr = parts.first, let start = Int64(startStr) else { return nil }
        let end: Int64
        if parts.count > 1, !parts[1].isEmpty, let e = Int64(parts[1]) { end = e } else { end = total - 1 }
        guard start <= end, start < total else { return nil }
        return (start, Swift.min(end, total - 1))
    }
}
