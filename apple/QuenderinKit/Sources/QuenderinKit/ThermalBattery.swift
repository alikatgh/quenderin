import Foundation

/// What sustained on-device generation actually does to heat and battery — the honest
/// "what to expect" surface. Calibrated from measured 2024–2026 phone data (see
/// apple/REALITY.md): realistic ranges, not spec-sheet promises.
public struct ThermalBatteryEstimate: Sendable, Equatable, Codable {
    /// Battery (mAh) to generate 1,000 tokens. Memory-bound, so ≈ const × params.
    public let mAhPer1KTokens: Double
    /// Battery used per hour of CONTINUOUS active generation, as % of THIS device's battery.
    public let activeDrainPercentPerHour: Double
    /// Sustained tok/s once the SoC thermally throttles (minutes into continuous load).
    public let sustainedTokensPerSecond: Double
    /// Fraction of peak speed retained when throttled (measured drops span 10–44%).
    public let throttledFraction: Double
    /// Plain verdict for bursty chat — the 95% case (phone barely warms, trivial cost).
    public let chatVerdict: String
    /// Honest warning for sustained / agent-loop use (heat + throttle + drain).
    public let sustainedVerdict: String
}

/// Turns a model + chip + battery + peak speed into an honest heat/battery expectation.
public enum ThermalBattery {

    /// Energy per token scales with model size — decode streams the whole model from
    /// memory for every token. Anchored to a measured ~35 mAh per 1,000 tokens for a 7B
    /// Q4 model (≈4.5–8.3 mAh per 192-token round, arXiv 2410.03613): 35 / 7 ≈ 5.
    public static let mAhPer1KTokensPerBillionParams = 5.0

    /// Speed retained once the SoC throttles under sustained load. Measured losses range
    /// 10–20% (Snapdragon 8 Gen 3) to 44% (iPhone 16 Pro); we use a ~35%-loss midpoint
    /// and label it as a range, not a promise.
    public static let throttledFraction = 0.65

    /// Tokens in a typical single chat reply (for the per-reply cost framing).
    public static let typicalReplyTokens = 300.0

    public static func estimate(
        for model: ModelEntry,
        chip: AppleChip,
        batteryMAh: Double,
        peakTokensPerSecond: Double
    ) -> ThermalBatteryEstimate {
        let mAhPer1K = mAhPer1KTokensPerBillionParams * model.paramsBillions
        let sustainedTokS = peakTokensPerSecond * throttledFraction

        // Continuous: sustained tokens/hr × mAh/token → mAh/hr → % of battery.
        let mAhPerHour = sustainedTokS * 3600.0 * (mAhPer1K / 1000.0)
        let drainPctPerHour = batteryMAh > 0 ? (mAhPerHour / batteryMAh) * 100.0 : 0

        let mAhPerReply = mAhPer1K * (typicalReplyTokens / 1000.0)
        let replyPct = batteryMAh > 0 ? (mAhPerReply / batteryMAh) * 100.0 : 0
        let lossPct = Int(((1 - throttledFraction) * 100).rounded())

        let chat = String(
            format: "Light for chat — a typical reply costs ~%@%% battery and barely warms the phone.",
            replyPct < 0.1 ? "0.1" : String(format: "%.1f", replyPct)
        )
        let sustained = String(
            format: "Sustained / agent use: the phone warms and throttles ~%d%% slower after a few minutes, drawing ~%d%%/hr of continuous generation.",
            lossPct, Int(drainPctPerHour.rounded())
        )

        return ThermalBatteryEstimate(
            mAhPer1KTokens: mAhPer1K,
            activeDrainPercentPerHour: drainPctPerHour,
            sustainedTokensPerSecond: sustainedTokS,
            throttledFraction: throttledFraction,
            chatVerdict: chat,
            sustainedVerdict: sustained
        )
    }
}
