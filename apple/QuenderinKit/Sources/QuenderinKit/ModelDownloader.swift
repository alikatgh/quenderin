import Foundation

/// An event in a model download. Progress is fractional (0...1); `finished`
/// carries the final on-disk location.
public enum DownloadEvent: Sendable, Equatable {
    case progress(Double)
    case finished(URL)
}

public enum DownloadError: Error, Sendable, Equatable {
    case invalidURL
    case writeFailed(reason: String)
    case transport(reason: String)
    case cancelled
}

/// Fetches a model module onto the device. A protocol seam so the onboarding
/// flow can be tested against a mock and the app can swap implementations.
public protocol ModelDownloader: Sendable {
    /// Stream progress while downloading `url` to `destination`. The stream
    /// finishes after a `.finished` event, or throws a `DownloadError`.
    func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error>
}

/// Foreground `URLSession` downloader with streamed progress.
///
/// > This is the simple version — fine for bring-up. Production should port the
/// > **background** `URLSession` engine from
/// > `off-grid-mobile/ios/DownloadManagerModule.swift` (resumable, survives app
/// > suspension, multi-file), minus the React Native bridge.
public struct URLSessionModelDownloader: ModelDownloader {
    private let configuration: URLSessionConfiguration

    public init(session: URLSession = .shared) {
        // Drive our own delegate-backed session, but inherit the provided session's configuration
        // so URLProtocol-based test stubs (set on the configuration) still intercept requests.
        self.configuration = session.configuration
    }

    public func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let delegate = ChunkedDownloadDelegate(sourceURL: url, destination: destination, continuation: continuation)
            // A dedicated delegate queue serializes the didReceive* callbacks, so the delegate's
            // mutable state is touched on one thread at a time (see its @unchecked Sendable note).
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            let task = session.dataTask(with: url)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
}

/// Streams a download to disk in the OS's native ~16–64 KB chunks via `URLSessionDataDelegate`,
/// instead of iterating `URLSession.bytes` one `UInt8` at a time. The per-byte AsyncBytes loop pegs a
/// CPU core and caps throughput on multi-GB GGUFs (audit perf HIGH #6); native `Data` chunks don't.
/// Reports fractional progress and runs the C3 integrity gate before signaling success.
///
/// `@unchecked Sendable`: all mutable state is mutated only inside the URLSession delegate callbacks,
/// which the single-width `delegateQueue` above delivers serially — never concurrently.
private final class ChunkedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let destination: URL
    private let partial: URL
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation

    private var handle: FileHandle?
    private var total: Int64 = -1
    private var downloaded: Int64 = 0
    private var lastReported = 0.0
    private var finished = false

    init(sourceURL: URL, destination: URL, continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.partial = destination.appendingPathExtension("partial")
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            handle = try FileHandle(forWritingTo: partial)
            total = response.expectedContentLength  // -1 if unknown
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            downloaded += Int64(data.count)
            if total > 0 {
                let fraction = Double(downloaded) / Double(total)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    continuation.yield(.progress(fraction))
                }
            }
        } catch {
            dataTask.cancel()
            finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        try? handle?.close()
        handle = nil

        if let error {
            try? FileManager.default.removeItem(at: partial)
            let mapped = (error as? URLError)?.code == .cancelled
                ? DownloadError.cancelled
                : DownloadError.transport(reason: String(describing: error))
            finish(throwing: mapped)
            return
        }
        if finished { return }  // a write error already finished us; partial is gone

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            // Integrity gate (C3): verify before signaling success — a MITM, poisoned mirror, or
            // truncated transfer must not reach the GGUF parser. Resolve the expected SHA-256 from
            // the catalog by URL (nil → GGUF magic-header check only).
            let expectedSHA = ModelCatalog.models.first { $0.downloadURL == sourceURL }?.sha256
            try ModelIntegrity.verify(fileURL: destination, expectedSHA256: expectedSHA)
            continuation.yield(.progress(1.0))
            continuation.yield(.finished(destination))
            finish(throwing: nil)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            finish(throwing: error)
        }
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        continuation.finish(throwing: error)
    }
}
