import Foundation

/// Resumable, background-capable model downloader.
///
/// Built on a **background** `URLSession`, so a download keeps running when the
/// app is suspended — the exact failure a foreground downloader hits when the
/// off-grid user switches apps mid-download. Progress is mirrored into a
/// `DownloadStore` so it can be reported/resumed after relaunch.
///
/// > The live background behavior (survives suspension; the system relaunches the
/// > app to deliver completion) needs a device/simulator plus the app's
/// > `handleEventsForBackgroundURLSession` hook to verify end-to-end. The
/// > persistence/resume bookkeeping is unit-tested via `DownloadStore`; this
/// > class wires `URLSession` to it. Conforms to `ModelDownloader`, so it drops
/// > into `OnboardingModel` in place of the foreground downloader.
public final class BackgroundModelDownloader: NSObject, ModelDownloader, @unchecked Sendable {
    private let store: DownloadStore
    private let sessionIdentifier: String
    private let lock = NSLock()
    private var continuations: [Int: AsyncThrowingStream<DownloadEvent, Error>.Continuation] = [:]
    private var destinations: [Int: URL] = [:]
    private var resolvedIDs: [Int: String] = [:]

    public init(store: DownloadStore, sessionIdentifier: String = "ai.quenderin.modeldownload") {
        self.store = store
        self.sessionIdentifier = sessionIdentifier
        super.init()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true  // gate cellular at the DownloadPolicy layer, not here
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - ModelDownloader

    public func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        // Resolve the catalog id from the URL so the integrity gate (C3) in didFinishDownloadingTo
        // can look up the pinned SHA-256. lastPathComponent is the FILENAME, not the id, so
        // ModelCatalog.entry(id:) would miss and silently downgrade to magic-only verification.
        download(from: url, to: destination, modelId: Self.catalogModelId(for: url, destination: destination))
    }

    /// The catalog model id for a download URL (so the SHA-256 gate can find the pinned hash);
    /// falls back to the filename for genuinely off-catalog downloads.
    static func catalogModelId(for url: URL, destination: URL) -> String {
        ModelCatalog.models.first { $0.downloadURL == url }?.id ?? destination.lastPathComponent
    }

    public func download(from url: URL, to destination: URL, modelId: String) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                continuation.finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
                return
            }

            let task = session.downloadTask(with: url)
            let id = task.taskIdentifier
            let resolved = modelId.isEmpty ? destination.lastPathComponent : modelId

            lock.lock()
            continuations[id] = continuation
            destinations[id] = destination
            resolvedIDs[id] = resolved
            lock.unlock()

            let record = PersistedDownload(
                modelId: resolved,
                fileName: destination.lastPathComponent,
                urlString: url.absoluteString,
                destinationPath: destination.path
            )
            Task { await store.upsert(record) }

            // Don't cancel a background download just because a consumer stops
            // listening — it should keep running while the app is away.
            task.resume()
        }
    }

    /// Records that were mid-flight when the app last died — candidates to resume.
    public func resumableDownloads() async -> [PersistedDownload] {
        await store.resumable()
    }

    // MARK: - Private

    private func cleanup(_ id: Int) {
        lock.lock()
        continuations[id] = nil
        destinations[id] = nil
        resolvedIDs[id] = nil
        lock.unlock()
    }
}

extension BackgroundModelDownloader: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let id = downloadTask.taskIdentifier
        lock.lock()
        let continuation = continuations[id]
        let resolved = resolvedIDs[id] ?? String(id)
        lock.unlock()

        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        continuation?.yield(.progress(fraction))
        Task { await store.updateProgress(modelId: resolved, bytesDownloaded: totalBytesWritten, totalBytes: totalBytesExpectedToWrite) }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let id = downloadTask.taskIdentifier
        lock.lock()
        let continuation = continuations[id]
        let destination = destinations[id]
        let resolved = resolvedIDs[id] ?? String(id)
        lock.unlock()

        guard let destination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            // Must move synchronously — URLSession deletes `location` on return.
            try FileManager.default.moveItem(at: location, to: destination)
            // Integrity gate (C3): verify before signaling success — a MITM, poisoned mirror,
            // or truncated transfer must not reach the GGUF parser. Expected SHA-256 comes
            // from the catalog by model id (nil → GGUF magic-header check only).
            try ModelIntegrity.verify(fileURL: destination, expectedSHA256: ModelCatalog.entry(id: resolved)?.sha256)
            continuation?.yield(.progress(1.0))
            continuation?.yield(.finished(destination))
            continuation?.finish()
            Task { await store.remove(modelId: resolved) }
        } catch {
            // Includes integrity failure — don't keep a corrupt/unverified file for resume.
            try? FileManager.default.removeItem(at: destination)
            continuation?.finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
            Task { await store.setState(modelId: resolved, .failed) }
        }
        cleanup(id)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let id = task.taskIdentifier
        lock.lock()
        let continuation = continuations[id]
        let resolved = resolvedIDs[id] ?? String(id)
        lock.unlock()

        if let error {
            continuation?.finish(throwing: DownloadError.transport(reason: error.localizedDescription))
            Task { await store.setState(modelId: resolved, .failed) }
            cleanup(id)
        }
    }
}
