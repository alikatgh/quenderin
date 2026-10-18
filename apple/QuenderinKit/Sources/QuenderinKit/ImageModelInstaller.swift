import Foundation
import CryptoKit

public protocol ImageComponentDownloading: Sendable {
    func download(_ component: ImageModelComponent, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error>
}

public actor ImageModelInstaller {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quenderin/image-models", isDirectory: true)
            .resolvingSymlinksInPath()
    }
    public let directory: URL
    private let downloader: any ImageComponentDownloading

    public init(directory: URL = ImageModelInstaller.defaultDirectory,
                downloader: any ImageComponentDownloading = ImageComponentDownloader()) {
        self.directory = directory
        self.downloader = downloader
    }

    public func install(_ model: ImageModel, budget: ImageResourceBudget, imported: [URL] = [],
                        publisherTermsAccepted: Bool = false,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try model.validate()
        if let reason = budget.blockReason(for: model, installing: false) { throw ImageGenerationError.invalid(reason) }
        if model.requiresPublisherAccess && (!publisherTermsAccepted || imported.isEmpty) {
            throw ImageGenerationError.invalid("Review the publisher terms and import the files obtained with your publisher access.")
        }
        let target = directory.appendingPathComponent(model.id, isDirectory: true)
        let remaining = try Self.remainingDownloadBytes(model, in: target)
        if let reason = budget.blockReason(for: model, installing: true, remainingDownloadBytes: remaining) {
            throw ImageGenerationError.invalid(reason)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard target.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else {
            throw ImageGenerationError.invalid("The image model folder must not contain symbolic links.")
        }
        var completed: Int64 = 0
        for component in model.components {
            try Task.checkCancellation()
            let final = target.appendingPathComponent(component.localFilename)
            if FileManager.default.fileExists(atPath: final.path) {
                try Self.verify(component, at: final)
            } else {
                let staging = target.appendingPathComponent(".\(UUID().uuidString).partial")
                defer { try? FileManager.default.removeItem(at: staging) }
                if !imported.isEmpty {
                    let choices = imported.filter {
                        $0.lastPathComponent == component.localFilename || $0.lastPathComponent == URL(fileURLWithPath: component.filename).lastPathComponent
                    }
                    guard choices.count == 1, let source = choices.first else {
                        throw ImageGenerationError.invalid("Choose exactly one file for \(component.localFilename), including every model component.")
                    }
                    let accessing = source.startAccessingSecurityScopedResource()
                    defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                    try Self.copy(source, to: staging, expectedBytes: component.bytes) { bytes in
                        progress(Double(completed + bytes) / Double(model.downloadBytes))
                    }
                } else {
                    guard component.access == "public" else { throw ImageGenerationError.invalid("This file requires publisher access. Import it after reviewing the publisher terms.") }
                    let base = completed
                    for try await event in downloader.download(component, to: staging) {
                        if case .progress(let fraction) = event {
                            progress((Double(base) + Double(component.bytes) * fraction) / Double(model.downloadBytes))
                        }
                    }
                }
                try Task.checkCancellation()
                try Self.verify(component, at: staging)
                // Never replace an existing file or the user's imported original.
                guard !FileManager.default.fileExists(atPath: final.path) else {
                    throw ImageGenerationError.invalid("Another installation already created this component. Retry verification.")
                }
                try FileManager.default.moveItem(at: staging, to: final)
            }
            completed += component.bytes
            progress(Double(completed) / Double(model.downloadBytes))
        }
        try Self.verify(model, in: target)
        return target
    }

    /// A retained file reduces the install reservation only after full checksum verification.
    /// Corrupt files cause a visible failure and remain in place; installation never replaces them.
    public static func remainingDownloadBytes(_ model: ImageModel, in directory: URL, cancelled: () -> Bool = { false }) throws -> Int64 {
        try model.validate()
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw ImageGenerationError.invalid("The image model folder must not contain symbolic links.")
        }
        var remaining: Int64 = 0
        for component in model.components {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            let file = directory.appendingPathComponent(component.localFilename)
            if FileManager.default.fileExists(atPath: file.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
                try verify(component, at: file, cancelled: cancelled)
            } else { remaining += component.bytes }
        }
        return remaining
    }

    public static func verify(_ model: ImageModel, in directory: URL, cancelled: () -> Bool = { false }) throws {
        try model.validate()
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw ImageGenerationError.invalid("The image model folder must not contain symbolic links.")
        }
        for component in model.components {
            try verify(component, at: directory.appendingPathComponent(component.localFilename), cancelled: cancelled)
        }
    }

    private static func verify(_ component: ImageModelComponent, at url: URL, cancelled: () -> Bool = { false }) throws {
        let identity = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard identity.isRegularFile == true, identity.isSymbolicLink != true, Int64(identity.fileSize ?? -1) == component.bytes else {
            throw ImageGenerationError.invalid("Missing or incomplete \(component.localFilename). Existing files were preserved.")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            hasher.update(data: data)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard actual == component.sha256, after.fileSize == identity.fileSize,
              after.contentModificationDate == identity.contentModificationDate else {
            throw ImageGenerationError.invalid("Checksum failed for \(component.localFilename). The existing file was preserved.")
        }
    }

    private static func copy(_ source: URL, to destination: URL, expectedBytes: Int64, progress: (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ImageGenerationError.invalid("Could not create an image component staging file.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count: Int64 = 0
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= expectedBytes else { throw ImageGenerationError.invalid("Imported component is larger than its pinned artifact.") }
            try output.write(contentsOf: data)
            progress(count)
        }
        guard count == expectedBytes else { throw ImageGenerationError.invalid("Imported component is incomplete.") }
    }
}

/// Native chunk callbacks keep transport memory bounded; exact byte count and digest stop bad bodies.
public struct ImageComponentDownloader: ImageComponentDownloading {
    public init() {}
    public func download(_ component: ImageModelComponent, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let delegate = ImageComponentDownloadDelegate(component, destination, continuation)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 7_200
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            let task = session.dataTask(with: component.downloadURL)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
}

private final class ImageComponentDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let component: ImageModelComponent
    private let destination: URL
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    private var handle: FileHandle?
    private var bytes: Int64 = 0
    private var hasher = SHA256()
    private var finished = false
    private var redirects = 0
    private var reported: Double = 0

    init(_ component: ImageModelComponent, _ destination: URL, _ continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.component = component; self.destination = destination; self.continuation = continuation
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        completionHandler(redirects <= 8 && request.url?.scheme == "https" ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength < 0 || response.expectedContentLength == component.bytes else {
            completionHandler(.cancel)
            finish(session, ImageGenerationError.invalid("The server did not return the complete pinned component.")); return
        }
        do {
            guard !FileManager.default.fileExists(atPath: destination.path), FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ImageGenerationError.invalid("Could not create a new image component file.")
            }
            handle = try FileHandle(forWritingTo: destination)
            completionHandler(.allow)
        } catch { completionHandler(.cancel); finish(session, error) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let handle else { return }
        do {
            guard bytes + Int64(data.count) <= component.bytes else { throw ImageGenerationError.invalid("Download exceeds the pinned component size.") }
            try handle.write(contentsOf: data)
            hasher.update(data: data); bytes += Int64(data.count)
            let fraction = Double(bytes) / Double(component.bytes)
            if fraction - reported >= 0.002 { reported = fraction; continuation.yield(.progress(fraction)) }
        } catch { finish(session, error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(session, error); return }
        guard bytes == component.bytes, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == component.sha256 else {
            finish(session, ImageGenerationError.invalid("Downloaded component failed its exact size or checksum check.")); return
        }
        finish(session, nil)
    }
    private func finish(_ session: URLSession, _ error: Error?) {
        guard !finished else { return }
        finished = true
        try? handle?.close(); handle = nil
        if let error { continuation.finish(throwing: error) }
        else { continuation.yield(.finished(destination)); continuation.finish() }
        session.invalidateAndCancel()
    }
}
