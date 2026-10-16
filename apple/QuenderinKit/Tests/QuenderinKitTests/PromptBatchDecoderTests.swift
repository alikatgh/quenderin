import XCTest
@testable import QuenderinKit

final class PromptBatchDecoderTests: XCTestCase {
    func testStopBeforePrefillDoesNoNativeWork() {
        let result = PromptBatchDecoder.decode(tokenCount: 1200, batchSize: 512,
            isCancelled: { true }, decodeBatch: { _ in XCTFail("decode after Stop"); return 0 })
        XCTAssertEqual(result, .cancelled)
    }

    func testStopDuringBatchSkipsRemainingPrompt() {
        var stopped = false
        var ranges: [Range<Int>] = []
        let result = PromptBatchDecoder.decode(tokenCount: 1200, batchSize: 2048,
            isCancelled: { stopped }) { range in
                ranges.append(range)
                stopped = true
                return 0
            }
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(ranges, [0..<512])
    }

    func testStopDuringFinalBatchIsNotReportedAsSuccess() {
        var stopped = false
        let result = PromptBatchDecoder.decode(tokenCount: 1, batchSize: 512,
            isCancelled: { stopped }) { _ in stopped = true; return 0 }
        XCTAssertEqual(result, .cancelled)
    }

    func testNativeFailureStopsWithoutDecodingMoreTokens() {
        var calls = 0
        let result = PromptBatchDecoder.decode(tokenCount: 1200, batchSize: 512,
            isCancelled: { false }) { _ in calls += 1; return -7 }
        XCTAssertEqual(result, .decoded(-7))
        XCTAssertEqual(calls, 1)
    }

    func testNativeLimitAndRemainderAreRespected() {
        var ranges: [Range<Int>] = []
        let result = PromptBatchDecoder.decode(tokenCount: 601, batchSize: 256,
            isCancelled: { false }) { ranges.append($0); return 0 }
        XCTAssertEqual(result, .decoded(0))
        XCTAssertEqual(ranges, [0..<256, 256..<512, 512..<601])
    }

    func testEmptyPromptAndZeroBatchCannotLoop() {
        XCTAssertEqual(PromptBatchDecoder.decode(tokenCount: 0, batchSize: 0,
            isCancelled: { false }, decodeBatch: { _ in XCTFail("empty decode"); return 0 }), .decoded(0))
        var calls = 0
        XCTAssertEqual(PromptBatchDecoder.decode(tokenCount: 2, batchSize: 0,
            isCancelled: { false }, decodeBatch: { _ in calls += 1; return 0 }), .decoded(0))
        XCTAssertEqual(calls, 2)
    }
}
