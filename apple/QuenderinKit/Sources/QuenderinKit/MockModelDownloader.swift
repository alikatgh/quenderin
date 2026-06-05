import Foundation

/// A deterministic `ModelDownloader` for previews and tests. Emits a fixed
/// number of progress steps, then writes an empty placeholder file at the
/// destination and finishes. Never touches the network.
public struct MockModelDownloader: ModelDownloader {
    public enum Behavior: Sendable, Equatable {
        case succeed
        case failTransport(reason: String)
    }

    private let behavior: Behavior
    private let steps: Int

    public init(behavior: Behavior = .succeed, steps: Int = 4) {
        self.behavior = behavior
        self.steps = max(1, steps)
    }

    public func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        let behavior = self.behavior
        let steps = self.steps
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .failTransport(let reason):
                continuation.finish(throwing: DownloadError.transport(reason: reason))
            case .succeed:
                for step in 1...steps {
                    continuation.yield(.progress(Double(step) / Double(steps)))
                }
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    FileManager.default.createFile(atPath: destination.path, contents: Data())
                    continuation.yield(.finished(destination))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: DownloadError.writeFailed(reason: String(describing: error)))
                }
            }
        }
    }
}
