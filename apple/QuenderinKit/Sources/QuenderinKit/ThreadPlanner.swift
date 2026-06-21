import Foundation

/// Picks the inference thread count for a device. On heterogeneous mobile SoCs (Apple's
/// performance/efficiency cores, Android big.LITTLE) scheduling matmul-heavy decode onto the
/// efficiency cores is **slower and hotter** than using the performance cores alone — the slow
/// cores bottleneck the others and add heat. So target the performance-core count, clamped to
/// `[1, totalCores]`, with the old "all-but-one" heuristic as a fallback when the P-core count
/// is unknown. Pure + deterministic → testable. Twin of Android `ThreadPlanner`.
public enum ThreadPlanner {
    public static func recommend(performanceCores: Int?, totalCores: Int) -> Int {
        let total = max(1, totalCores)
        if let p = performanceCores, p >= 1, p <= total { return p }
        return max(1, total - 1)   // unknown P-core count → the previous heuristic
    }
}
