import XCTest
@testable import QuenderinKit

/// Exercises the REAL `URLSessionModelDownloader` (delegate-based chunked download, audit perf HIGH #6)
/// end-to-end via a `URLProtocol` stub — the protocol-contract tests use a mock, so this is the only
/// coverage of the actual networking → file → integrity-gate path.
final class URLSessionModelDownloaderTests: XCTestCase {

    private func makeDownloader() -> URLSessionModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionModelDownloader(session: URLSession(configuration: config))
    }

    private func tempDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-real-dl-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model.gguf")
    }

    func testWritesFileReportsMonotonicProgressAndFinishes() async throws {
        // Leading "GGUF" magic so the C3 integrity gate (magic-only — this URL isn't in the catalog,
        // so there's no pinned SHA-256) accepts the file.
        var body = Data([0x47, 0x47, 0x55, 0x46])  // "GGUF"
        body.append(Data(repeating: 0xAB, count: 4096))
        StubURLProtocol.reset(body: body)

        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        var progresses: [Double] = []
        var finished: URL?
        for try await event in makeDownloader().download(from: URL(string: "https://example.com/m.gguf")!, to: destination) {
            switch event {
            case .progress(let fraction): progresses.append(fraction)
            case .finished(let url): finished = url
            }
        }

        XCTAssertEqual(finished, destination)
        XCTAssertFalse(progresses.isEmpty, "should report progress")
        XCTAssertEqual(progresses, progresses.sorted(), "progress must be monotonic")
        XCTAssertEqual(try XCTUnwrap(progresses.last), 1.0, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "file should be written")
        XCTAssertEqual(try Data(contentsOf: destination), body, "written bytes match the response body")
        // The .partial temp must not be left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    /// Root-cause regression for App Review 2.1a (0.2.0(9)): a catalog URL that 404'd streamed
    /// HuggingFace's "Entry not found" body to disk, which then failed the GGUF magic check and
    /// surfaced as a cryptic `ModelIntegrityError`. A non-2xx status must now be rejected up front
    /// as a clear transport error — and crucially the error body must NEVER be written (so it can't
    /// reach the integrity gate), even when, as here, that body isn't GGUF.
    func testNon2xxResponseThrowsTransportAndWritesNoFile() async {
        StubURLProtocol.reset(body: Data("Entry not found".utf8), statusCode: 404)
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            for try await _ in makeDownloader().download(from: URL(string: "https://example.com/dead.gguf")!, to: destination) {}
            XCTFail("expected the stream to throw on a 404")
        } catch let error as DownloadError {
            guard case .transport(let reason) = error else { return XCTFail("expected .transport, got \(error)") }
            XCTAssertTrue(reason.contains("404"), "transport reason should name the status: \(reason)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no model file on a 404")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path),
                       "the 404 error body must never be written to the .partial file")
    }

    func testTransportFailureThrowsAndLeavesNoFile() async {
        StubURLProtocol.reset(body: Data(), failError: URLError(.notConnectedToInternet))
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            for try await _ in makeDownloader().download(from: URL(string: "https://example.com/m.gguf")!, to: destination) {}
            XCTFail("expected the stream to throw")
        } catch let error as DownloadError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }
}

/// Minimal in-memory `URLProtocol` stub. Serves a fixed body in two chunks (to exercise progress),
/// or fails the load. Test-only; state is set on the main test thread before each request starts.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var failError: Error?
    nonisolated(unsafe) static var statusCode = 200

    static func reset(body: Data, failError: Error? = nil, statusCode: Int = 200) {
        responseBody = body
        self.failError = failError
        self.statusCode = statusCode
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client = client else { return }
        if let failError = Self.failError {
            client.urlProtocol(self, didFailWithError: failError)
            return
        }
        let body = Self.responseBody
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count)]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let mid = body.count / 2
        if mid > 0 { client.urlProtocol(self, didLoad: body.subdata(in: 0..<mid)) }
        client.urlProtocol(self, didLoad: body.subdata(in: mid..<body.count))
        client.urlProtocolDidFinishLoading(self)
    }
}
