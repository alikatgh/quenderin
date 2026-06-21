import Foundation

/// The data type of the KV (attention) cache. The cache grows linearly with context length and,
/// on a memory-tight phone, is what tips a model that "fits by weights" into a jetsam kill.
/// Quantizing it to `q8_0` roughly halves that cost at near-zero quality loss — so the same memory
/// holds ~2× the context (or the chosen context fits with real margin). Twin of Android `KVCacheType`.
///
/// We stop at `q8_0`: it's safe on llama.cpp's standard (non-flash-attention) path for BOTH the K
/// and V cache. Going to `q4_0` for the V cache requires flash attention — a separate change to
/// enable + validate on-device — so it's deliberately out of scope here.
public enum KVCacheType: String, Sendable, Equatable, Codable {
    case f16
    case q8_0

    /// Memory per cached token relative to `f16` (q8_0 ≈ 53% — 8 bits + block scale overhead).
    public var relativeCostPerToken: Double {
        switch self {
        case .f16:  return 1.0
        case .q8_0: return 0.53
        }
    }
}

/// Chooses the KV-cache dtype from the memory left after the model weights load. Roomy → keep
/// full-precision `f16` (best quality, the cache is cheap relative to budget); tight → `q8_0` so a
/// constrained phone still gets a usable context instead of a 512-token stub. Pure + testable.
/// Twin of Android `KVCachePolicy`. Uses the same headroom formula as `ContextWindow`.
public enum KVCachePolicy {
    public static func recommend(appBudgetGB: Double, modelWeightsGB: Double) -> KVCacheType {
        let headroomGB = appBudgetGB - modelWeightsGB * 1.15   // free after weights + overhead
        // ≥ 1.2 GB free → f16 is affordable; below that, halve the cache to buy back context.
        return headroomGB >= 1.2 ? .f16 : .q8_0
    }
}
