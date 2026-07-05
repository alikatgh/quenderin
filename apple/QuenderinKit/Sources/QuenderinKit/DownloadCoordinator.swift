import Foundation

/// Process-wide in-flight-download guard, keyed by destination filename (Q-003).
///
/// Two independent registries write the SAME `modelsDir/<filename>` (and the same
/// `<filename>.partial` staging file): the onboarding installer (`OnboardingModel.install`)
/// and the library page (`ModelLibraryController.download`). If both start the same model,
/// two `URLSession` writers interleave bytes into one partial file and corrupt it. This actor
/// is the single coordination point they share: a claim on a filename is exclusive, so the
/// target file can never have two concurrent writers. Release is idempotent.
///
/// Deliberately tiny and lives in QuenderinKit (not shared/) — it coordinates only these two
/// Apple-side writers; the parity-canonical layers are untouched.
public actor DownloadCoordinator {
    public static let shared = DownloadCoordinator()

    /// Filenames with a download currently in flight.
    private var claimed: Set<String> = []

    public init() {}

    /// Claim exclusive write access to `filename`. Returns `true` if the caller may proceed
    /// (no other writer holds it); `false` if a download to the same file is already in flight —
    /// the caller must NOT write, or it would corrupt the shared partial/destination.
    public func claim(_ filename: String) -> Bool {
        claimed.insert(filename).inserted
    }

    /// Release a previously-claimed filename. Idempotent — safe to call in a `defer` on every path.
    public func release(_ filename: String) {
        claimed.remove(filename)
    }

    /// Whether a download to `filename` is currently in flight (test/inspection aid).
    public func isClaimed(_ filename: String) -> Bool {
        claimed.contains(filename)
    }
}
