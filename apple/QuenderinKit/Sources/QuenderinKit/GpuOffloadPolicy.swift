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
        fileSizeGB <= deviceBudgetGB ? allLayers : cpuOnly
    }
}
