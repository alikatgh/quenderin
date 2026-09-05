import Foundation

/// Decides WHEN a streaming reply's partial text is pushed into the transcript (and therefore
/// re-rendered), instead of once per token.
///
/// Why: every transcript write costs a full SwiftUI diff of the message list plus a Markdown
/// re-parse of the whole reply (`MarkdownText` caches by full text — zero hits while the text
/// grows). At 80 tok/s on a Mac that is 80 list diffs + 80 parses a second, more than a display
/// refresh, and the stall users attribute to "the model". Cloud chat UIs coalesce tokens to
/// display frames; so do we: the first piece lands immediately (the bubble must show text the
/// instant the model speaks), then at most one write per `interval` (~30 Hz), then the settle
/// write at the end. The engine still streams token by token — only the UI write is paced.
/// Pure + Sendable so the policy unit-tests without a clock. Kotlin twin: `StreamFlushGate.kt`.
public struct StreamFlushGate: Sendable, Equatable {
    /// ~30 writes/s: one display frame at 30 Hz, and finer than anyone reads.
    public static let defaultInterval: Duration = .milliseconds(33)

    public let interval: Duration
    private var lastFlush: ContinuousClock.Instant?

    public init(interval: Duration = StreamFlushGate.defaultInterval) {
        self.interval = interval
    }

    /// True when the partial text should be written now: always for the first piece, then only
    /// once `interval` has elapsed since the last write. Records the flush when it returns true.
    public mutating func shouldFlush(now: ContinuousClock.Instant) -> Bool {
        if let last = lastFlush, now - last < interval { return false }
        lastFlush = now
        return true
    }

    public mutating func shouldFlush() -> Bool { shouldFlush(now: .now) }
}
