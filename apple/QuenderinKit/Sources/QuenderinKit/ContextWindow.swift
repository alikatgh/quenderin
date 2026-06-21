import Foundation

/// Picks the inference context window (`n_ctx`) for a device's total RAM. The KV cache grows with
/// `n_ctx` and sits on top of the model weights, so a fixed 4096 can push a memory-tight phone into
/// jetsam even for a model that "fits" by weights alone (audit M1). Smaller context on smaller
/// devices trades a shorter memory for not getting OOM-killed. Pure + deterministic → testable.
/// Twin of Android `ContextWindow`.
public enum ContextWindow {
    public static func recommend(totalRAMGB: Double) -> Int {
        switch totalRAMGB {
        case ..<4:  return 1024   // 2–3 GB phones: keep the KV cache small
        case ..<6:  return 2048   // 4 GB
        default:    return 4096   // 6 GB+
        }
    }
}
