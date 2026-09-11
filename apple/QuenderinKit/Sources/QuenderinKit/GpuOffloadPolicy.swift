import Foundation

/// Decides how many layers to offload to Metal (llama.cpp `n_gpu_layers`) on Apple.
///
/// Twin of Android's `GpuOffloadPlanner`, with a different reason to exist: Apple's Metal
/// driver is uniform (no Vulkan-style per-vendor safety problem), so for years the right
/// answer was an unconditional 999 — every shipped model fit RAM. A paged MoE breaks that
/// assumption: Metal *wires* offloaded weights into the GPU working set
/// (`recommendedMaxWorkingSetSize` ≈ 65–75% of unified RAM), so offloading a file bigger
/// than the budget doesn't gracefully page — it thrashes or fails the load. CPU-only +
/// `use_mmap` hands paging to the OS page cache instead, which streams the routed experts
/// from disk (read-only pages, no swap writes) — the verified configuration for
/// running a 13 GB 35B-A3B on a 16 GB Mac at 17.3 tok/s.
///
/// Pure + testable; the engine passes the *actual* GGUF file size, not an estimate.
public enum GpuOffloadPolicy {
    /// llama.cpp sentinel for "offload every layer" (matches Android's ALL_LAYERS).
    public static let allLayers: Int32 = 999
    public static let cpuOnly: Int32 = 0

    /// All layers on Metal when the weights genuinely fit the app budget; otherwise CPU-only
    /// so the OS page cache streams what doesn't fit. The budget is the same
    /// `appMemoryBudgetGB` that sizes the KV cache — if the file alone exceeds it, wiring
    /// it into the GPU working set can only end badly.
    public static func nGpuLayers(fileSizeGB: Double, deviceBudgetGB: Double) -> Int32 {
        #if targetEnvironment(simulator)
        // The iOS-simulator Metal compute path yields GARBAGE tokens (symbol soup) — the
        // smoketest knew this (QUENDERIN_NGL=0 workaround) but the engine never did, and the
        // app shipped sim chats that decoded junk. CPU-only in the simulator, always; real
        // devices keep Metal. (docs/BUG_JOURNAL.md 2026-07-11)
        return cpuOnly
        #else
        return fileSizeGB <= deviceBudgetGB ? allLayers : cpuOnly
        #endif
    }

    /// Where a model's routed MoE experts live. `.cpu` streams them from the OS page cache
    /// (mmap) while the dense spine stays wherever `nGpuLayers` puts it; `.gpu` keeps them
    /// with the rest of the weights.
    public enum ExpertPlacement: Sendable, Equatable {
        case gpu
        case cpu
    }

    /// One model's full offload decision.
    public struct OffloadPlan: Sendable, Equatable {
        public let nGpuLayers: Int32
        public let experts: ExpertPlacement
        public init(nGpuLayers: Int32, experts: ExpertPlacement) {
            self.nGpuLayers = nGpuLayers
            self.experts = experts
        }
    }

    /// The expert-tensor regex llama.cpp's own `--cpu-moe` uses (`common.h` `LLM_FFN_EXPS_REGEX`).
    /// Single source of truth so the engine and its tests agree.
    public static let moeExpertTensorPattern = "\\.ffn_(up|down|gate|gate_up)_(ch|)exps"

    /// The full offload decision, including expert placement.
    ///
    /// `expertOffloadEnabled` is the experiment switch (edge0's portable half — llama.cpp's
    /// `--cpu-moe` semantics). OFF (default) reproduces the historical all-or-nothing behavior:
    /// a model that doesn't fit the budget runs CPU-only. ON keeps a paged MoE's small dense
    /// spine on Metal and streams ONLY the routed experts from CPU/mmap, so Metal never has to
    /// wire the whole file into its working set. A dense model has nothing to split, so it is
    /// unaffected either way.
    public static func plan(fileSizeGB: Double, deviceBudgetGB: Double, isMoE: Bool,
                            expertOffloadEnabled: Bool = false) -> OffloadPlan {
        #if targetEnvironment(simulator)
        return OffloadPlan(nGpuLayers: cpuOnly, experts: .cpu)
        #else
        if fileSizeGB <= deviceBudgetGB {
            return OffloadPlan(nGpuLayers: allLayers, experts: .gpu)
        }
        if isMoE && expertOffloadEnabled {
            return OffloadPlan(nGpuLayers: allLayers, experts: .cpu)
        }
        return OffloadPlan(nGpuLayers: cpuOnly, experts: .cpu)
        #endif
    }
}
