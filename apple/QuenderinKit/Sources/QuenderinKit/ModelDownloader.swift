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
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let (bytes, response) = try await session.bytes(from: url)
                    let total = response.expectedContentLength  // -1 if unknown

                    let partial = destination.appendingPathExtension("partial")
                    FileManager.default.createFile(atPath: partial.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: partial)
                    defer { try? handle.close() }  // close on success, throw, or cancellation — no fd leak

                    var downloaded: Int64 = 0
                    var chunk = Data()
                    chunk.reserveCapacity(1 << 16)
                    var lastReported = 0.0

                    for try await byte in bytes {
                        chunk.append(byte)
                        downloaded += 1
                        if chunk.count >= (1 << 16) {
                            try handle.write(contentsOf: chunk)
                            chunk.removeAll(keepingCapacity: true)
                            if total > 0 {
                                let fraction = Double(downloaded) / Double(total)
                                if fraction - lastReported >= 0.01 {
                                    lastReported = fraction
                                    continuation.yield(.progress(fraction))
                                }
                            }
                        }
                    }
                    if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
                    try handle.close()

                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: partial, to: destination)

                    // Integrity gate (C3): verify the finished file before signaling success —
                    // a MITM, poisoned mirror, or truncated transfer must not reach the GGUF
                    // parser. The protocol only carries url+destination, so resolve the expected
                    // SHA-256 from the catalog by URL (nil → GGUF magic-header check only).
                    let expectedSHA = ModelCatalog.models.first { $0.downloadURL == url }?.sha256
                    do {
                        try ModelIntegrity.verify(fileURL: destination, expectedSHA256: expectedSHA)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        continuation.finish(throwing: error)
                        return
                    }

                    continuation.yield(.progress(1.0))
                    continuation.yield(.finished(destination))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DownloadError.cancelled)
                } catch {
                    continuation.finish(throwing: DownloadError.transport(reason: String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
