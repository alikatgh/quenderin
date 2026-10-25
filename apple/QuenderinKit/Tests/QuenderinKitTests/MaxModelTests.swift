import CMaxModel
import CryptoKit
import XCTest
@testable import QuenderinKit

private final class FakeState: @unchecked Sendable {
    var step = 0
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var blockClose = false
    let closeEntered = DispatchSemaphore(value: 0)
    let closeRelease = DispatchSemaphore(value: 0)
}

private final class ResultBox: @unchecked Sendable {
    var value: MaxGenerationResult?
}

private final class CloseBox: @unchecked Sendable {
    var value: MaxCloseResult?
}

private final class FirstCall: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if first { first = false; return true }
        return false
    }
}

nonisolated(unsafe) private var fakeLastState: FakeState?

private let fakeScript: [(bytes: [UInt8], eog: Bool)] = [
    (Array("he".utf8), false), (Array("llo".utf8), false), (Array(" ".utf8), false),
    ([0xC3], false), ([0xA9], false), (Array("!".utf8), true),
]

private func fakeOpen(_ receipt: UnsafePointer<QMaxModelReceipt>?,
                      _ error: UnsafeMutablePointer<QMaxError>?) -> UnsafeMutableRawPointer? {
    let state = FakeState()
    fakeLastState = state
    return Unmanaged.passRetained(state).toOpaque()
}

private func fakeTokenize(_ runner: UnsafeMutableRawPointer?, _ utf8: UnsafePointer<CChar>?,
                          _ bytes: Int, _ tokens: UnsafeMutablePointer<Int32>?, _ capacity: Int,
                          _ count: UnsafeMutablePointer<Int>?,
                          _ error: UnsafeMutablePointer<QMaxError>?) -> QMaxCode {
    guard let runner, let utf8, let tokens, let count, bytes >= 1 else { return qmax_code_invalid() }
    let state = Unmanaged<FakeState>.fromOpaque(runner).takeUnretainedValue()
    state.step = 0
    let data = Data(bytes: utf8, count: bytes)
    if data.starts(with: Array("__block__".utf8)) {
        state.entered.signal()
        if state.release.wait(timeout: .now() + 10) != .success { return qmax_code_invalid() }
    }
    guard bytes <= capacity else { return qmax_code_contract() }
    for index in 0..<bytes { tokens[index] = Int32(index) }
    count.pointee = bytes
    return qmax_code_ok()
}

private func fakeNext(_ runner: UnsafeMutableRawPointer?, _ tokens: UnsafePointer<Int32>?,
                      _ count: Int, _ temperature: Float, _ topP: Float, _ seed: UInt32,
                      _ token: UnsafeMutablePointer<Int32>?, _ piece: UnsafeMutablePointer<CChar>?,
                      _ capacity: Int, _ pieceBytes: UnsafeMutablePointer<Int>?,
                      _ endOfGeneration: UnsafeMutablePointer<Int32>?,
                      _ error: UnsafeMutablePointer<QMaxError>?) -> QMaxCode {
    guard let runner, let token, let piece, let pieceBytes, let endOfGeneration else {
        return qmax_code_invalid()
    }
    let state = Unmanaged<FakeState>.fromOpaque(runner).takeUnretainedValue()
    guard state.step < fakeScript.count else { return qmax_code_contract() }
    let current = fakeScript[state.step]
    guard current.bytes.count <= capacity else { return qmax_code_contract() }
    current.bytes.withUnsafeBytes { raw in
        if let base = raw.baseAddress { memcpy(piece, base, current.bytes.count) }
    }
    token.pointee = Int32(100 + state.step)
    pieceBytes.pointee = current.bytes.count
    endOfGeneration.pointee = current.eog ? 1 : 0
    state.step += 1
    return qmax_code_ok()
}

private func fakeClose(_ runner: UnsafeMutableRawPointer?) {
    guard let runner else { return }
    let state = Unmanaged<FakeState>.fromOpaque(runner).takeUnretainedValue()
    if state.blockClose {
        state.closeEntered.signal()
        _ = state.closeRelease.wait(timeout: .now() + 10)
    }
    Unmanaged<FakeState>.fromOpaque(runner).release()
}

private func makeFakeRunner() -> QMaxModelRunner {
    var runner = QMaxModelRunner()
    runner.abi = qmax_runner_abi()
    runner.open = fakeOpen
    runner.tokenize = fakeTokenize
    runner.next_token = fakeNext
    runner.close = fakeClose
    return runner
}

final class MaxModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        setenv("MODULAR_TELEMETRY_ENABLED", "0", 1)
        setenv("MODULAR_CRASH_REPORTING_ENABLED", "0", 1)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quenderin-max-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ name: String, _ text: String) throws -> MaxModelFile {
        let url = directory.appendingPathComponent(name)
        let data = Data(text.utf8)
        try data.write(to: url)
        return MaxModelFile(path: url.path, bytes: Int64(data.count), sha256: digest(data))
    }

    private func receipt() throws -> MaxModelReceipt {
        try MaxModelReceipt(
            files: [try write("graph.mef", "MEF synthetic graph\n"),
                    try write("tokenizer.bin", "tokenizer synthetic\n")],
            runnerName: "fake-bonsai-runner", backend: "cpu", contextTokens: 64, maxOutputTokens: 16)
    }

    func testReceiptVerifyAndTamper() throws {
        let value = try receipt()
        XCTAssertTrue(MaxModelBinding.verify(value).succeeded)
        var tamperedFiles = value.files
        tamperedFiles[0] = MaxModelFile(path: tamperedFiles[0].path, bytes: tamperedFiles[0].bytes,
                                        sha256: String(repeating: "0", count: 64))
        let tampered = try MaxModelReceipt(files: tamperedFiles, runnerName: value.runnerName,
                                           backend: value.backend, contextTokens: value.contextTokens,
                                           maxOutputTokens: value.maxOutputTokens)
        XCTAssertFalse(MaxModelBinding.verify(tampered).succeeded)
        XCTAssertThrowsError(try MaxModelReceipt(files: [MaxModelFile(path: "relative", bytes: 1,
                                                                     sha256: String(repeating: "a", count: 64))],
                                                 runnerName: "r", backend: "cpu", contextTokens: 16,
                                                 maxOutputTokens: 4))
    }

    func testUnavailableWithoutRunner() throws {
        let value = try receipt()
        let result = MaxModelBinding.open(value, runner: nil)
        guard case .failure(let error) = result else { return XCTFail("open succeeded without a runner") }
        XCTAssertEqual(error.code, 2)
        XCTAssertFalse(MaxModelBinding.capability(value, runner: nil).available)
    }

    func testGenerateCancelReuseAndClose() throws {
        let value = try receipt()
        var runner = makeFakeRunner()
        let opened = MaxModelBinding.open(value, runner: &runner)
        guard case .success(let handle) = opened else { return XCTFail("open failed") }
        XCTAssertTrue(MaxModelBinding.capability(value, runner: &runner, loadProbePassed: true).available)

        var text = ""
        let generated = handle.generate(prompt: "hi") { text += $0; return true }
        XCTAssertTrue(generated.succeeded)
        XCTAssertEqual(text, "hello \u{00E9}!")
        XCTAssertEqual(generated.performance.promptTokens, 2)
        XCTAssertEqual(generated.performance.decodedTokens, 6)

        let exotic = handle.generate(prompt: "\u{1F642}\0x", maxTokens: 4) { _ in true }
        XCTAssertTrue(exotic.succeeded)

        let cancelled = handle.generate(prompt: "hi") { _ in handle.cancel(); return true }
        XCTAssertEqual(cancelled.code, Int(qmax_code_value(qmax_code_cancelled())))
        XCTAssertEqual(cancelled.performance.status, 1)

        XCTAssertTrue(handle.generate(prompt: "hi") { _ in true }.succeeded)
        XCTAssertEqual(handle.close(), .closed)
        XCTAssertEqual(handle.close(), .closed)
        XCTAssertEqual(handle.generate(prompt: "hi") { _ in true }.code,
                       Int(qmax_code_value(qmax_code_invalid())))
    }

    func testCancelBeforeFirstToken() throws {
        let value = try receipt()
        var runner = makeFakeRunner()
        let opened = MaxModelBinding.open(value, runner: &runner)
        guard case .success(let handle) = opened else { return XCTFail("open failed") }
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = handle.generate(prompt: "__block__ hi") { _ in true }
        }
        XCTAssertEqual(fakeLastState?.entered.wait(timeout: .now() + 5), .success)
        handle.cancel()
        fakeLastState?.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(box.value?.code, Int(qmax_code_value(qmax_code_cancelled())))
        XCTAssertEqual(box.value?.performance.status, 1)
        XCTAssertEqual(handle.close(), .closed)
    }

    func testBusyAndCloseWaits() throws {
        let value = try receipt()
        var runner = makeFakeRunner()
        let opened = MaxModelBinding.open(value, runner: &runner)
        guard case .success(let handle) = opened else { return XCTFail("open failed") }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let workerDone = DispatchSemaphore(value: 0)
        let first = FirstCall()
        let worker = ResultBox()
        DispatchQueue.global().async {
            worker.value = handle.generate(prompt: "hi") { _ in
                if first.take() {
                    entered.signal()
                    release.wait()
                }
                return true
            }
            workerDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(handle.generate(prompt: "hi") { _ in true }.code,
                       Int(qmax_code_value(qmax_code_busy())))
        let closeBox = CloseBox()
        let closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            closeBox.value = handle.close()
            closeDone.signal()
        }
        XCTAssertEqual(closeDone.wait(timeout: .now() + 0.2), .timedOut)
        release.signal()
        XCTAssertEqual(workerDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(closeDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(worker.value?.succeeded, true)
        XCTAssertEqual(closeBox.value, .closed)
    }

    func testCloseFromCallbackIsRefused() throws {
        let value = try receipt()
        var runner = makeFakeRunner()
        let opened = MaxModelBinding.open(value, runner: &runner)
        guard case .success(let handle) = opened else { return XCTFail("open failed") }
        let result = handle.generate(prompt: "hi") { _ in
            _ = handle.close()
            return true
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(handle.isClosed)
        XCTAssertEqual(handle.close(), .closed)
    }

    func testCancelWaitsForCloseLease() throws {
        let value = try receipt()
        var runner = makeFakeRunner()
        let opened = MaxModelBinding.open(value, runner: &runner)
        guard case .success(let handle) = opened else { return XCTFail("open failed") }
        guard let state = fakeLastState else { return XCTFail("missing fake runner state") }
        state.blockClose = true
        let closeBox = CloseBox()
        let closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            closeBox.value = handle.close()
            closeDone.signal()
        }
        XCTAssertEqual(state.closeEntered.wait(timeout: .now() + 5), .success)
        let cancelDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            handle.cancel()
            cancelDone.signal()
        }
        // cancel must block on the pointer lock while close owns the model lease.
        XCTAssertEqual(cancelDone.wait(timeout: .now() + 0.2), .timedOut)
        state.closeRelease.signal()
        XCTAssertEqual(closeDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(cancelDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(closeBox.value, .closed)
        XCTAssertTrue(handle.isClosed)
    }
}
