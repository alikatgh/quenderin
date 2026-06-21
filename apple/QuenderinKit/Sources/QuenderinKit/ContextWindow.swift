import Foundation

/// Picks the inference context window (`n_ctx`) for a device's total RAM. The KV cache grows with
/// `n_ctx` and sits on top of the model weights, so a fixed 4096 can push a memory-tight phone into
/// jetsam even for a model that "fits" by weights alone (audit M1). Smaller context on smaller
/// devices trades a shorter memory for not getting OOM-killed. Pure + deterministic → testable.
/// Twin of Android `ContextWindow`.
public enum ContextWindow {
    /// RAM-band fallback (used when the chosen model isn't known yet).
    public static func recommend(totalRAMGB: Double) -> Int {
        switch totalRAMGB {
        case ..<4:  return 1024   // 2–3 GB phones: keep the KV cache small
        case ..<6:  return 2048   // 4 GB
        default:    return 4096   // 6 GB+
        }
    }

    /// Footprint-aware: size `n_ctx` from the device's real app-memory budget AND the chosen
    /// model's weights, so a 1B leaves room for a big context while a 7B on the same phone is
    /// capped tight — the headroom after the weights load is what's left for the KV cache.
    /// `appBudgetGB` is the *app-memory* budget (iOS jetsam / Android native-heap), NOT total RAM.
    public static func recommend(appBudgetGB: Double, modelWeightsGB: Double) -> Int {
        let headroomGB = appBudgetGB - modelWeightsGB * 1.15   // free after weights + overhead
        switch headroomGB {
        case ..<0.25: return 512    // barely fits the weights — minimal KV cache
        case ..<0.6:  return 1024
        case ..<1.2:  return 2048
        default:      return 4096
        }
    }

    /// Cache-aware: a quantized KV cache costs less per token, so the *same* KV-memory budget holds
    /// proportionally more tokens. We size the f16 context for the headroom, then scale it by the
    /// inverse per-token cost of the chosen dtype (q8_0 ≈ +90% context for the same memory), clamped
    /// to a sane ceiling and rounded to a 256-token multiple. The `f16` case is identical to the
    /// 2-arg overload, so existing behaviour is unchanged unless quantization is actually requested.
    public static func recommend(appBudgetGB: Double, modelWeightsGB: Double, kvCacheType: KVCacheType) -> Int {
        let base = recommend(appBudgetGB: appBudgetGB, modelWeightsGB: modelWeightsGB)
        let scaled = Double(base) / kvCacheType.relativeCostPerToken
        let rounded = Int((scaled / 256.0).rounded()) * 256
        return min(8192, max(256, rounded))
    }
}
