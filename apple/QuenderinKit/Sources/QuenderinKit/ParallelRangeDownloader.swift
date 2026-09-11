import Foundation

/// Parallel (multi-connection) ranged downloader — the fast path for multi-GB models.
///
/// Today's `URLSessionModelDownloader` opens ONE connection, which is capped by `RTT × window`
/// against a distant CDN. This probe-and-fan-out downloader issues N concurrent `Range:` GETs
/// over one `URLSession`, writing each disjoint region at its file offset, then runs the SAME
/// C3 integrity gate. If the server doesn't honor ranges it falls back to the single-stream
/// downloader, so correctness never depends on the CDN.
public struct ParallelRangeDownloader: ModelDownloader {
    private let configuration: URLSessionConfiguration
    private let maxConnections: Int
    private let isCellular: Bool

    public init(session: URLSession = .shared, maxConnections: Int = 6, isCellular: Bool = false) {
        self.configuration = session.configuration
        self.maxConnections = maxConnections
        self.isCellular = isCellular
    }

    public func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        download(from: url, to: destination, expectedSHA256: nil)
    }

    public func download(from url: URL, to destination: URL, expectedSHA256: String?) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let coordinator = ParallelDownloadCoordinator(
                sourceURL: url,
                destination: destination,
                expectedSHA256: expectedSHA256,
                maxConnections: maxConnections,
                isCellular: isCellular,
                configuration: configuration,
                continuation: continuation
            )
            continuation.onTermination = { _ in coordinator.cancel() }
            coordinator.start()
        }
    }
}

/// Drives the probe → fan-out → verify sequence. All mutable state is touched only from the
/// single-width delegate queue (and `start`/`cancel`, guarded by `lock`), so it is safe without
/// actor isolation — same contract as `ChunkedDownloadDelegate`.
private final class ParallelDownloadCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let destination: URL
    private let partial: URL
    private let expectedSHA256: String?
    private let maxConnections: Int
    private let isCellular: Bool
    private let configuration: URLSessionConfiguration
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation

    private let lock = NSLock()
    private var session: URLSession?
    private var probeTaskID: Int?
    private var plan: DownloadSegments?
    private var downloaded: [Int64] = []
    private var completed: Set<Int> = []
    private var taskToSegment: [Int: Int] = [:]
    private var handle: FileHandle?
    private var lastReported = 0.0
    private var finished = false

    init(sourceURL: URL, destination: URL, expectedSHA256: String?, maxConnections: Int,
         isCellular: Bool, configuration: URLSessionConfiguration,
         continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.partial = destination.appendingPathExtension("partial")
        self.expectedSHA256 = expectedSHA256
        self.maxConnections = maxConnections
        self.isCellular = isCellular
        self.configuration = configuration
        self.continuation = continuation
    }

    func start() {
        lock.lock()
        guard session == nil else { lock.unlock(); return }
        // Serial delegate queue: every callback below runs one at a time, so the mutable state
        // (downloaded[], handle) needs no locking.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session = s
        lock.unlock()

        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")  // 1-byte probe
        let task = s.dataTask(with: request)
        lock.lock(); probeTaskID = task.taskIdentifier; lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let s = session
        lock.unlock()
        s?.invalidateAndCancel()
    }

    // MARK: - Delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: DownloadError.transport(reason: "non-HTTP response"))
            return
        }

        lock.lock()
        let isProbe = (id == probeTaskID)
        lock.unlock()

        if isProbe {
            // Parallel only when the server proves range support: 206 + a parseable total.
            if http.statusCode == 206, let total = Self.totalBytes(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")), total > 0 {
                completionHandler(.cancel)   // the 1-byte probe body is discarded
                beginParallel(total: total, session: session)
            } else {
                // No range support (200/other) — fall back to the proven single-stream path.
                completionHandler(.cancel)
                fallbackToSingleStream()
            }
            return
        }

        // A segment response. Require 206; a 200 here means the server ignored Range and would
        // double-write, so fail clearly rather than corrupt the file.
        guard http.statusCode == 206 else {
            completionHandler(.cancel)
            finish(throwing: DownloadError.transport(reason: "range request returned HTTP \(http.statusCode)"))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        lock.lock()
        let segIndex = taskToSegment[id]
        let plan = self.plan
        let handle = self.handle
        lock.unlock()

        guard let segIndex, let plan, let handle, segIndex < plan.segments.count else { return }
        let segment = plan.segments[segIndex]

        lock.lock()
        let offset = segment.start + downloaded[segIndex]
        downloaded[segIndex] += Int64(data.count)
        let progress = plan.fraction(downloadedPerSegment: downloaded)
        let shouldReport = progress - lastReported >= 0.01
        if shouldReport { lastReported = progress }
        lock.unlock()

        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
            return
        }
        if shouldReport { continuation.yield(.progress(progress)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        if let error {
            // A cancelled probe/segment is a normal step (probe discards its body; segment tasks
            // are only cancelled on a real failure) — don't surface it unless we're still running.
            if (error as? URLError)?.code == .cancelled { return }
            finish(throwing: DownloadError.transport(reason: error.localizedDescription))
            return
        }

        lock.lock()
        let segIndex = taskToSegment[id]
        if let segIndex { completed.insert(segIndex) }
        let allDone = (plan != nil) && (completed.count == (plan?.segments.count ?? 0))
        lock.unlock()

        if allDone { assembleAndVerify() }
    }

    // MARK: - Phases

    private func beginParallel(total: Int64, session: URLSession) {
        let count = DownloadSegments.connectionCount(totalBytes: total, isCellular: isCellular, max: maxConnections)
        let plan = DownloadSegments(totalBytes: total, segmentCount: count)

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let h = try FileHandle(forWritingTo: partial)
            try h.truncate(atOffset: UInt64(total))   // preallocate so offset writes land correctly
            lock.lock()
            self.plan = plan
            self.downloaded = Array(repeating: 0, count: plan.segments.count)
            self.handle = h
            lock.unlock()
        } catch {
            finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
            return
        }

        for segment in plan.segments {
            var request = URLRequest(url: sourceURL)
            request.setValue("bytes=\(segment.start)-\(segment.end)", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: request)
            lock.lock(); taskToSegment[task.taskIdentifier] = segment.index; lock.unlock()
            task.resume()
        }
    }

    private func fallbackToSingleStream() {
        lock.lock()
        let s = session
        lock.unlock()
        s?.invalidateAndCancel()
        let single = URLSessionModelDownloader(session: URLSession(configuration: configuration))
        Task {
            do {
                for try await event in single.download(from: sourceURL, to: destination, expectedSHA256: expectedSHA256) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func assembleAndVerify() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let handle = self.handle
        let session = self.session
        lock.unlock()

        try? handle?.close()
        session?.invalidateAndCancel()

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            let expectedSHA = expectedSHA256 ?? ModelCatalog.models.first { $0.downloadURL == sourceURL }?.sha256
            try ModelIntegrity.verify(fileURL: destination, expectedSHA256: expectedSHA)
            continuation.yield(.progress(1.0))
            continuation.yield(.finished(destination))
            continuation.finish()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: partial)
            continuation.finish(throwing: error)
        }
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let handle = self.handle
        let session = self.session
        lock.unlock()

        try? handle?.close()
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: partial)
        continuation.finish(throwing: error)
    }

    /// `Content-Range: bytes 0-0/13211155424` → `13211155424`. Nil when absent/`*`/malformed.
    static func totalBytes(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        let tail = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard tail != "*" else { return nil }
        return Int64(tail)
    }
}
