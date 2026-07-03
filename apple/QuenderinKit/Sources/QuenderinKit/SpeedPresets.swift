import Foundation

/// The speed↔quality trade the user picked.
public enum SpeedPreset: String, CaseIterable, Sendable {
    case fast, balanced, quality
}

/// The model-speed dial: maps Fast / Balanced / Quality to concrete catalog models for a device's
/// RAM. Decode speed is memory-bandwidth-bound — tokens/sec scales ~inversely with model bytes — so
/// the model SIZE is the one speed lever that actually moves the felt experience (a 1B streams ~6×
/// faster than the 4B). QUALITY is always the device recommendation; FAST/BALANCED step down from
/// it. Bands collapse on small devices (dup entries are fine). Pure + testable; twin of Kotlin
/// `SpeedPresets`.
public enum SpeedPresets {
    public struct Choice: Sendable {
        public let fast: ModelEntry
        public let balanced: ModelEntry
        public let quality: ModelEntry

        public func model(_ preset: SpeedPreset) -> ModelEntry {
            switch preset {
            case .fast: return fast
            case .balanced: return balanced
            case .quality: return quality
            }
        }

        /// Which preset a model id corresponds to, or nil for a manual pick outside the dial.
        /// Checked quality-first so on small devices (collapsed bands) the strongest label wins.
        public func preset(for modelID: String) -> SpeedPreset? {
            switch modelID {
            case quality.id: return .quality
            case balanced.id: return .balanced
            case fast.id: return .fast
            default: return nil
            }
        }
    }

    public static func forDevice(totalRAMGB: Double) -> Choice {
        // Fitness-aware, not the raw band: Quality must never point at a model the memory gate
        // blocks (16 GB → band says 14B, budget says no — the dial would offer a doomed install).
        let quality = ModelRecommender.bestInstallableModel(forTotalRAMGB: totalRAMGB)
        let fastCand: ModelEntry
        let balancedCand: ModelEntry
        switch totalRAMGB {
        case ..<3.0:
            fastCand = entry("llama32-1b-q2"); balancedCand = entry("llama32-1b")
        case ..<10.0:
            fastCand = entry("llama32-1b"); balancedCand = entry("llama32-3b")
        default:
            fastCand = entry("llama32-3b"); balancedCand = entry("qwen3-4b")
        }
        // Clamp so the dial is never upside-down: on the tiniest devices the RECOMMENDED model is
        // already the smallest, so a band's "balanced" could outweigh quality — collapse it instead.
        let balanced = balancedCand.ramGB > quality.ramGB ? quality : balancedCand
        let fast = fastCand.ramGB > balanced.ramGB ? balanced : fastCand
        return Choice(fast: fast, balanced: balanced, quality: quality)
    }

    private static func entry(_ id: String) -> ModelEntry {
        ModelCatalog.entry(id: id) ?? ModelCatalog.models.last!
    }
}
