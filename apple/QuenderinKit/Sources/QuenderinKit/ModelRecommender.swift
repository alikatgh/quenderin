import Foundation

/// Picks the right model "module" for a device's RAM.
/// Direct port of `getRecommendedModelIdForTotalRam` / `getHardwareRecommendation`
/// in `quenderin/src/constants.ts`. The thresholds (1.5 / 3 / 6 GB) are covered
/// by the same boundary tests as the desktop suite — keep them identical.
public enum ModelRecommender {

    /// Concrete catalog id for a device's total RAM (GB).
    public static func recommendedModelID(forTotalRAMGB ram: Double) -> String {
        if ram < 1.5 { return "llama32-1b-q2" }
        if ram < 3   { return "llama32-1b" }
        if ram < 4   { return "llama32-3b" }
        if ram < 10  { return "qwen3-4b" }   // the current go-to for mainstream devices
        return "qwen3-14b"
    }

    /// Resolved catalog entry for a device's total RAM. Falls back to the
    /// smallest model if the id somehow isn't in the catalog (cannot happen for
    /// the four ids above, but keeps this total and crash-free).
    public static func recommendedModel(forTotalRAMGB ram: Double) -> ModelEntry {
        ModelCatalog.entry(id: recommendedModelID(forTotalRAMGB: ram)) ?? ModelCatalog.smallest
    }

    /// Max params + quantization the hardware tier allows. Mirrors
    /// `getHardwareRecommendation` (defaults to the 1B/Q4_K_M floor).
    public static func recommendation(
        forTotalRAMGB ram: Double
    ) -> (maxParamsBillions: Double, quantization: String, totalRAMGB: Double) {
        let tier = HardwareTiers.all.first { ram >= $0.minRAMGB && ram < $0.maxRAMGB }
        return (tier?.maxParamsBillions ?? 1, tier?.quantization ?? "Q4_K_M", ram)
    }

    /// Convenience: recommend straight from the live device probe.
    public static func recommendedModelForThisDevice() -> ModelEntry {
        recommendedModel(forTotalRAMGB: HardwareProbe.current().totalRAMGB)
    }
}
