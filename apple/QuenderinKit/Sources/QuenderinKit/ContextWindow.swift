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
}
