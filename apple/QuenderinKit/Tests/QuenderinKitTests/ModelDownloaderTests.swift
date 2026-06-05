import XCTest
@testable import QuenderinKit

final class ModelDownloaderTests: XCTestCase {

    private func tempDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-dl-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model.gguf")
    }

    func testMockSucceedYieldsMonotonicProgressThenFinished() async throws {
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let downloader = MockModelDownloader(steps: 5)
        var progresses: [Double] = []
        var finished: URL?

        for try await event in downloader.download(from: URL(string: "https://example.com/m.gguf")!, to: destination) {
            switch event {
            case .progress(let fraction): progresses.append(fraction)
            case .finished(let url): finished = url
            }
        }

        XCTAssertEqual(progresses.count, 5)
        XCTAssertEqual(progresses, progresses.sorted(), "progress must be monotonic")
        XCTAssertEqual(try XCTUnwrap(progresses.last), 1.0, accuracy: 0.0001)
        XCTAssertEqual(finished, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "file should be written")
    }

    func testMockFailureThrowsTransport() async {
        let destination = tempDestination()
        let downloader = MockModelDownloader(behavior: .failTransport(reason: "no network"))
        do {
            for try await _ in downloader.download(from: URL(string: "https://example.com/m.gguf")!, to: destination) {}
            XCTFail("expected the stream to throw")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .transport(reason: "no network"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
