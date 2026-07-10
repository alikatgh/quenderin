import Foundation

/// Mixture-of-Experts shape parsed from a model name — the key to running models far
/// bigger than RAM on consumer machines.
///
/// A MoE activates only a fraction of its weights per token (Qwen3.6-35B-A3B: 3B of 35B).
/// With `use_mmap` and the experts left pageable, the OS page cache streams the routed
/// experts from disk and only the dense spine + hot experts stay resident — measured
/// 17.3 tok/s for a 13 GB 35B-A3B on a 16 GB M4 with 4–6 GB resident and zero swap
/// (mmap'd weights are read-only: evictions are free, never swap writes). The dense
/// heuristics (`ramGB = file × 1.5`, params-capped filters) would call that model
/// "doesn't fit" — this type is how the search/fitness/engine paths know better.
public struct MoEShape: Sendable, Equatable {
    /// Total parameters (billions) — what the name advertises ("35B").
    public let totalParamsB: Double
    /// Active parameters per token (billions) — what a token actually runs ("A3B").
    public let activeParamsB: Double

    public init(totalParamsB: Double, activeParamsB: Double) {
        self.totalParamsB = totalParamsB
        self.activeParamsB = activeParamsB
    }

    /// The released GGUF convention: `…-<total>B-A<active>B…` (Qwen3-30B-A3B,
    /// Qwen3.6-35B-A3B, Qwen3-235B-A22B, GLM …). Case-insensitive; nil for dense
    /// models and for degenerate shapes (active must be a real fraction of total).
    public static func detect(_ name: String) -> MoEShape? {
        let lower = name.lowercased()
        guard let rx = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)b-a(\d+(?:\.\d+)?)b\b"#),
              let m = rx.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let totalR = Range(m.range(at: 1), in: lower),
              let activeR = Range(m.range(at: 2), in: lower),
              let total = Double(lower[totalR]),
              let active = Double(lower[activeR]),
              active > 0, active < total
        else { return nil }
        return MoEShape(totalParamsB: total, activeParamsB: active)
    }

    /// Resident-set estimate (GB) for a *paged* MoE: dense spine (attention, embeddings,
    /// shared experts) + the hot-expert working set + runtime, everything else streamed
    /// by the OS page cache. Calibrated against the measured 4–6 GB resident for the
    /// 13.2 GB Qwen3.x-35B-A3B (this formula → ~5.4), and 8 GB devices land in
    /// MemoryFitness's blocked band — honest: the spine alone starves them.
    /// Clamped so a fat-active MoE (Mixtral 2-of-8) never estimates below dense reality.
    public static func pagedResidentRamGB(fileSizeGB: Double, shape: MoEShape) -> Double {
        let paged = fileSizeGB * (shape.activeParamsB / shape.totalParamsB) * 4.5 + 0.3
        let dense = fileSizeGB * 1.5 + 0.3
        return min(paged, dense)
    }
}
