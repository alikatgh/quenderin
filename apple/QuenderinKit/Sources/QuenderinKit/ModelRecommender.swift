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

    /// The recommendation a UI can actually OFFER: the RAM-band pick when it passes the memory
    /// gate, else the largest catalog model that does (falling back to the smallest). The band
    /// function above stays 1:1 with desktop/Android; this wrapper exists because the band and
    /// `MemoryFitness` can disagree — a 16 GB Mac band-picks the 14B, which the 85% budget then
    /// blocks — and "RECOMMENDED FOR THIS DEVICE" must never sit on a model the same screen
    /// refuses to install.
    public static func bestInstallableModel(forTotalRAMGB ram: Double) -> ModelEntry {
        let banded = recommendedModel(forTotalRAMGB: ram)
        if MemoryFitness.check(model: banded, totalGB: ram, freeGB: ram).canLoad { return banded }
        let fitting = ModelCatalog.models
            .filter { MemoryFitness.check(model: $0, totalGB: ram, freeGB: ram).canLoad }
            .max { $0.ramGB < $1.ramGB }
        return fitting ?? ModelCatalog.smallest
    }

    /// Convenience: recommend straight from the live device probe.
    ///
    /// On iOS this defers to `IPhoneModelSelector`, which is jetsam-budget- and
    /// chip-aware — the naive total-RAM band would over-pick and risk the app being
    /// jetsam-killed. Elsewhere (desktop parity, tests) it uses the shared band logic.
    public static func recommendedModelForThisDevice() -> ModelEntry {
        #if os(iOS)
        return IPhoneModelSelector.selectForThisDevice().model
        #else
        return recommendedModel(forTotalRAMGB: HardwareProbe.current().totalRAMGB)
        #endif
    }

    /// The full, explained iPhone selection (model + rationale + alternatives) for a
    /// device profile. The app uses this to show *why* a model was chosen.
    public static func selection(for device: IOSDeviceProfile) -> ModelSelection {
        IPhoneModelSelector.select(for: device)
    }
}
