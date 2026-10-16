import XCTest
@testable import QuenderinKit

/// Every file is a few bytes of fake GGUF data. No network or model execution is used.
final class ModelArtifactSetTests: XCTestCase {
    private let firstData = Data("GGUFfake-A".utf8)
    private let secondData = Data("GGUFfake-second".utf8)

    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["QUENDERIN_TEST_SCRATCH"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: root).appendingPathComponent("split-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func fixture() throws -> ModelEntry {
        let dir = try directory()
        var parts: [ModelArtifact] = []
        for (name, data) in [("fixture-00001-of-00002.gguf", firstData), ("fixture-00002-of-00002.gguf", secondData)] {
            let file = dir.appendingPathComponent(name)
            try data.write(to: file)
            parts.append(ModelArtifact(filename: name,
                url: "https://huggingface.co/test/tiny-fixture/resolve/\(String(repeating: "a", count: 40))/\(name)",
                sha256: try ModelIntegrity.sha256Hex(of: file), downloadBytes: Int64(data.count)))
        }
        return entry(parts: parts)
    }

    private func entry(parts: [ModelArtifact], total: Int64? = nil) -> ModelEntry {
        let first = parts.first!
        return ModelEntry(id: "tiny-split", label: "Tiny fake fixture", filename: first.filename,
                          ramGB: 1, sizeLabel: "24 B", paramsBillions: 1, quantization: "Q2_K",
                          urlString: first.url, sha256: first.sha256,
                          downloadBytes: total ?? parts.reduce(0) { $0 + $1.downloadBytes }, artifacts: parts)
    }

    func testLegacyManifestDecodesWithoutArtifactsAndEmptyArrayKeepsSingleFile() throws {
        let json = #"{"id":"legacy","label":"Legacy","filename":"single.gguf","ramGb":1,"sizeLabel":"1 GB","paramsBillions":1,"quantization":"Q2_K","url":"https://example.invalid/single.gguf"}"#
        let old = try JSONDecoder().decode(ModelEntry.self, from: Data(json.utf8))
        XCTAssertNil(old.artifacts)
        XCTAssertFalse(ModelArtifactSet.isMultipart(old))
        XCTAssertEqual(ModelArtifactSet.filenames(old), ["single.gguf"])
        XCTAssertEqual(try ModelArtifactSet.validate(old), [])
        let emptyJSON = json.dropLast() + ",\"artifacts\":[]}"
        let empty = try JSONDecoder().decode(ModelEntry.self, from: Data(emptyJSON.utf8))
        XCTAssertFalse(ModelArtifactSet.isMultipart(empty))
        XCTAssertEqual(ModelArtifactSet.filenames(empty), ["single.gguf"])
    }

    func testRejectsUnsafeDuplicateUnpinnedAndOverflowingManifest() throws {
        let model = try fixture()
        let a = model.artifacts![0], b = model.artifacts![1]
        for badName in ["../escape.gguf", "folder/a.gguf", "folder\\a.gguf", ".hidden.gguf", "a\n.gguf"] {
            let bad = ModelArtifact(filename: badName, url: b.url, sha256: b.sha256, downloadBytes: b.downloadBytes)
            XCTAssertThrowsError(try ModelArtifactSet.validate(entry(parts: [a, bad])))
        }
        XCTAssertThrowsError(try ModelArtifactSet.validate(entry(parts: [a, a])))
        let unpinned = ModelArtifact(filename: b.filename, url: b.url.replacingOccurrences(of: String(repeating: "a", count: 40), with: "main"), sha256: b.sha256, downloadBytes: b.downloadBytes)
        XCTAssertThrowsError(try ModelArtifactSet.validate(entry(parts: [a, unpinned])))
        let huge = ModelArtifact(filename: a.filename, url: a.url, sha256: a.sha256, downloadBytes: Int64.max)
        XCTAssertThrowsError(try ModelArtifactSet.validate(entry(parts: [huge, b], total: Int64.max)))
        XCTAssertThrowsError(try ModelArtifactSet.validate(entry(parts: [a, b], total: 1)))
        let badHash = ModelArtifact(filename: b.filename, url: b.url, sha256: "not-a-hash", downloadBytes: b.downloadBytes)
        XCTAssertThrowsError(try ModelArtifactSet.validate(entry(parts: [a, badHash])))
    }

    func testFirstShardAloneIsNeverInstalledOrOfflineReady() throws {
        let model = try fixture()
        let parts = model.artifacts!
        let storage = InMemoryModelStorage([parts[0].filename: parts[0].downloadBytes])
        let manager = ModelManager(storage: storage, catalog: [model])
        XCTAssertFalse(manager.isInstalled(model.id))
        XCTAssertTrue(manager.installed().isEmpty)
        XCTAssertEqual(manager.totalBytesUsed, parts[0].downloadBytes)
        XCTAssertEqual(manager.reclaimableBytes, parts[0].downloadBytes)
        XCTAssertFalse(OfflineReadinessChecker.evaluate(model: model, fileExists: true, fileSizeBytes: Int64.max).isReadyForOffline)
        storage.install(parts[1].filename, sizeBytes: parts[1].downloadBytes)
        XCTAssertTrue(manager.isInstalled(model.id))
        XCTAssertEqual(manager.installed().first?.sizeBytes, model.downloadBytes)
        XCTAssertEqual(manager.delete(model.id), model.downloadBytes)
        XCTAssertTrue(storage.installedFilenames().isEmpty)
    }

    func testLiveCompletenessRejectsMissingOrCorruptSibling() throws {
        let model = try fixture()
        let dir = try directory()
        let first = dir.appendingPathComponent(model.filename)
        try firstData.write(to: first)
        XCTAssertThrowsError(try ModelArtifactSet.verify(model, firstFile: first))
        XCTAssertFalse(OfflineReadinessChecker.evaluate(model: model, in: dir).isReadyForOffline)
        let second = dir.appendingPathComponent(model.artifacts![1].filename)
        try Data(repeating: 120, count: secondData.count).write(to: second)
        XCTAssertThrowsError(try ModelArtifactSet.verify(model, firstFile: first))
        XCTAssertFalse(FileManagerModelStorage(directory: dir).isComplete(model))
        try secondData.write(to: second)
        XCTAssertNoThrow(try ModelArtifactSet.verify(model, firstFile: first))
        XCTAssertTrue(OfflineReadinessChecker.evaluate(model: model, in: dir).isReadyForOffline)
    }

    @MainActor
    func testInstallerAggregatesProgressAndReusesCompletedFiles() async throws {
        let model = try fixture()
        let dir = try directory()
        try firstData.write(to: dir.appendingPathComponent(model.filename))
        let fake = TinyArtifactDownloader(data: [model.artifacts![1].filename: secondData])
        var progress: [Double] = []
        let first = try await ModelArtifactInstaller.install(model, in: dir, downloader: fake, availableDiskBytes: { _ in Int64.max }) { progress.append($0) }
        XCTAssertEqual(first.lastPathComponent, model.filename)
        XCTAssertEqual(fake.requested, [model.artifacts![1].filename])
        XCTAssertEqual(progress.last, 1)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertNoThrow(try ModelArtifactSet.verify(model, firstFile: first))
    }

    @MainActor
    func testCancellationKeepsVerifiedFirstFileAndRetryFinishesRemainingPart() async throws {
        let model = try fixture()
        let dir = try directory()
        let files = [model.artifacts![0].filename: firstData, model.artifacts![1].filename: secondData]
        let fake = TinyArtifactDownloader(data: files)
        let task = Task { @MainActor in
            try await ModelArtifactInstaller.install(model, in: dir, downloader: fake, availableDiskBytes: { _ in Int64.max }) { fraction in
                if fraction >= Double(self.firstData.count) / Double(model.downloadBytes!), fraction < 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("cancel must stop the entire set") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(fake.requested, [model.filename])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.filename).path))
        XCTAssertFalse(FileManagerModelStorage(directory: dir).isComplete(model))
        let retry = TinyArtifactDownloader(data: files)
        _ = try await ModelArtifactInstaller.install(model, in: dir, downloader: retry, availableDiskBytes: { _ in Int64.max })
        XCTAssertEqual(retry.requested, [model.artifacts![1].filename])
    }

    @MainActor
    func testExistingCorruptPartIsPreservedWithoutNetwork() async throws {
        let model = try fixture()
        let dir = try directory()
        let file = dir.appendingPathComponent(model.filename)
        let existing = Data("user-existing-file".utf8)
        try existing.write(to: file)
        let fake = TinyArtifactDownloader(data: [:])
        do {
            _ = try await ModelArtifactInstaller.install(model, in: dir, downloader: fake, availableDiskBytes: { _ in Int64.max })
            XCTFail("existing invalid bytes require explicit removal")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), existing)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    @MainActor
    func testInstallerDiskPreflightStopsBeforeNetworkAndUsesOnlyMissingBytes() async throws {
        let model = try fixture()
        let dir = try directory()
        try firstData.write(to: dir.appendingPathComponent(model.filename))
        XCTAssertEqual(try ModelArtifactSet.remainingDownloadBytes(model, in: dir), Int64(secondData.count))
        let fake = TinyArtifactDownloader(data: [:])
        do {
            _ = try await ModelArtifactInstaller.install(model, in: dir, downloader: fake, availableDiskBytes: { _ in 0 })
            XCTFail("disk preflight must stop the download")
        } catch {}
        XCTAssertTrue(fake.requested.isEmpty)
        XCTAssertTrue(DiskSpace.check(model: model, availableBytes: Int64(secondData.count), marginBytes: 0,
                                     remainingDownloadBytes: Int64(secondData.count)).hasRoom)
    }

    @MainActor
    func testReceiptInvalidatesAfterSameSizeMutationAndHashingRunsOffMainThread() async throws {
        let model = try fixture()
        let dir = try directory()
        let first = dir.appendingPathComponent(model.filename)
        try firstData.write(to: first)
        try secondData.write(to: dir.appendingPathComponent(model.artifacts![1].filename))
        XCTAssertFalse(ModelArtifactSet.isVerified(model, firstFile: first))
        let offMain = try await ModelArtifactSet.inBackground { !Thread.isMainThread }
        XCTAssertTrue(offMain)
        try await ModelArtifactSet.verifyInBackground(model, firstFile: first)
        XCTAssertTrue(ModelArtifactSet.isVerified(model, firstFile: first))
        let date = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate]!
        try Data("GGUFfake-B".utf8).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: first.path)
        XCTAssertFalse(ModelArtifactSet.isVerified(model, firstFile: first), "ctime/inode invalidate proof even when size and mtime match")
        XCTAssertFalse(OfflineReadinessChecker.evaluate(model: model, in: dir).isReadyForOffline)
    }

    @MainActor
    func testInstallerHashFailureNeverReportsComplete() async throws {
        let model = try fixture()
        let dir = try directory()
        let bad = Data("GGUFwrong-bytes".utf8) // same byte count as the second fixture, wrong hash
        XCTAssertEqual(bad.count, secondData.count)
        let fake = TinyArtifactDownloader(data: [model.artifacts![0].filename: firstData, model.artifacts![1].filename: bad])
        do { _ = try await ModelArtifactInstaller.install(model, in: dir, downloader: fake, availableDiskBytes: { _ in Int64.max }); XCTFail("expected integrity failure") }
        catch is ModelIntegrityError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(FileManagerModelStorage(directory: dir).isComplete(model))
    }
}

private final class TinyArtifactDownloader: ModelDownloader, @unchecked Sendable {
    private let data: [String: Data]
    private let lock = NSLock()
    private var requests: [String] = []
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    init(data: [String: Data]) { self.data = data }

    func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); requests.append(destination.lastPathComponent); lock.unlock()
            do {
                guard let bytes = data[destination.lastPathComponent] else { throw DownloadError.invalidURL }
                try bytes.write(to: destination)
                continuation.yield(.progress(0.5))
                continuation.yield(.finished(destination))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}
