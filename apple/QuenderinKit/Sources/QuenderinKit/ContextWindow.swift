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

    /// Conservative f16 KV-cache footprint per cached token (0.5 MiB/token).
    /// Covers typical ≤8B–14B GQA models (~0.15 MiB/token) with margin plus MHA 7B models
    /// (~0.5 MiB/token) so a manual context choice never silently oversubscribes jetsam headroom.
    /// Scaled by `KVCacheType.relativeCostPerToken` (e.g. `0.53` for `q8_0`).
    public static let baseF16KVMBPerToken: Double = 0.5

    /// Estimated KV-cache memory in GiB for `tokens` at the given `kvCacheType`.
    public static func estimatedKVGB(tokens: Int, kvCacheType: KVCacheType) -> Double {
        guard tokens > 0 else { return 0.0 }
        return (Double(tokens) * baseF16KVMBPerToken * kvCacheType.relativeCostPerToken) / 1024.0
    }

    /// Resolves a user's `ContextLengthChoice` against the device's app-memory headroom.
    /// - `.auto`: exact 3-arg `recommend(...)` result, `warning == nil`.
    /// - Manual (`k2`/`k4`/`k8`):
    ///   - If `requested <= autoTokens`, returns `requested` with `warning == nil`.
    ///   - If `requested > autoTokens` and `estimatedKVGB <= headroomGB`, returns `requested` with `.moreMemory`.
    ///   - Otherwise clamps down to `autoTokens` and reports `.exceedsBudget`.
    public static func resolve(
        choice: ContextLengthChoice,
        appBudgetGB: Double,
        modelWeightsGB: Double,
        kvCacheType: KVCacheType
    ) -> ContextResolution {
        let autoTokens = recommend(
            appBudgetGB: appBudgetGB,
            modelWeightsGB: modelWeightsGB,
            kvCacheType: kvCacheType
        )
        guard let requested = choice.requestedTokens else {
            return ContextResolution(tokens: autoTokens, warning: nil)
        }
        if requested <= autoTokens {
            return ContextResolution(tokens: requested, warning: nil)
        }
        let headroomGB = appBudgetGB - modelWeightsGB * 1.15
        let requiredKVGB = estimatedKVGB(tokens: requested, kvCacheType: kvCacheType)
        if headroomGB > 0 && requiredKVGB <= headroomGB {
            return ContextResolution(tokens: requested, warning: .moreMemory)
        }
        return ContextResolution(tokens: autoTokens, warning: .exceedsBudget)
    }
}

/// User-selectable context length preference. Default is `.auto` (matches existing behaviour).
/// Twin of Android `ContextLengthChoice`.
public enum ContextLengthChoice: String, Sendable, Equatable, Codable, CaseIterable {
    case auto = "auto"
    case k2 = "2048"
    case k4 = "4096"
    case k8 = "8192"

    public static let defaultChoice: ContextLengthChoice = .auto

    /// Requested token count for manual choices, or `nil` for `.auto`.
    public var requestedTokens: Int? {
        switch self {
        case .auto: return nil
        case .k2: return 2048
        case .k4: return 4096
        case .k8: return 8192
        }
    }
}

/// Memory advisory produced when resolving a manual `ContextLengthChoice`.
/// Twin of Android `ContextWarning`.
public enum ContextWarning: String, Sendable, Equatable, Codable {
    /// Requested length is above Auto but still fits the estimated KV headroom.
    case moreMemory
    /// Requested length exceeds estimated KV headroom and was clamped down to Auto.
    case exceedsBudget
}

/// Result of resolving a `ContextLengthChoice` for a device and model.
/// Twin of Android `ContextResolution`.
public struct ContextResolution: Sendable, Equatable {
    public let tokens: Int
    public let warning: ContextWarning?

    public init(tokens: Int, warning: ContextWarning?) {
        self.tokens = tokens
        self.warning = warning
    }

    /// Short English advisory text for the UI, or `nil` when there is no warning.
    public var warningText: String? {
        switch warning {
        case nil:
            return nil
        case .moreMemory:
            return "Uses more memory. Long chats may be slower."
        case .exceedsBudget:
            return "Not enough memory on this device for this length; using \(tokens) tokens."
        }
    }
}
