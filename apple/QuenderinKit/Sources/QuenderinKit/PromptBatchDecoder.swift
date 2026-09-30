/// Bounded prompt processing for llama.cpp, with Stop checked at every batch boundary.
/// The native decoder stays synchronous; cancellation never frees a context mid-call.
enum PromptBatchDecoder {
    enum Result: Equatable {
        case decoded(Int32)
        case cancelled
    }

    static let maximumBatchTokens = 512

    static func decode(
        tokenCount: Int,
        batchSize: Int,
        isCancelled: () -> Bool,
        decodeBatch: (Range<Int>) -> Int32
    ) -> Result {
        let limit = max(1, min(batchSize, maximumBatchTokens))
        var start = 0
        while start < tokenCount {
            if isCancelled() { return .cancelled }
            let end = start + min(limit, tokenCount - start)
            let code = decodeBatch(start..<end)
            // A Stop during the final native call must also finish without a failure banner.
            if isCancelled() { return .cancelled }
            if code != 0 { return .decoded(code) }
            start = end
        }
        return isCancelled() ? .cancelled : .decoded(0)
    }
}
