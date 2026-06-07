import Foundation

/// Apple SoC families relevant to on-device LLM inference, newest → oldest, plus an
/// `unknown` fallback. `inferenceScore` is a RELATIVE decode-throughput multiplier
/// (A18 Pro ≡ 1.0) used to estimate tokens/sec — calibrated from public on-device
/// llama.cpp/MLX benchmarks, NOT a spec sheet. It's a heuristic ordering; real device
/// measurement (the on-device cliff) should refine it.
public enum AppleChip: String, Sendable, Equatable, Codable, CaseIterable {
    case a12, a13, a14, a15, a16, a17Pro, a18, a18Pro
    case mSeries   // iPad/Mac-class, included for completeness
    case unknown

    public var displayName: String {
        switch self {
        case .a12:     return "A12 Bionic"
        case .a13:     return "A13 Bionic"
        case .a14:     return "A14 Bionic"
        case .a15:     return "A15 Bionic"
        case .a16:     return "A16 Bionic"
        case .a17Pro:  return "A17 Pro"
        case .a18:     return "A18"
        case .a18Pro:  return "A18 Pro"
        case .mSeries: return "M-series"
        case .unknown: return "Apple silicon"
        }
    }

    /// Relative LLM decode throughput, A18 Pro ≡ 1.0. Newer chips have wider memory
    /// bandwidth, which is what bounds token generation on-device.
    public var inferenceScore: Double {
        switch self {
        case .a12:     return 0.30
        case .a13:     return 0.40
        case .a14:     return 0.50
        case .a15:     return 0.62
        case .a16:     return 0.72
        case .a17Pro:  return 0.85
        case .a18:     return 0.92
        case .a18Pro:  return 1.00
        case .mSeries: return 1.30
        case .unknown: return 0.55   // conservative middle for devices we don't know yet
        }
    }
}

/// A known iPhone: hardware identifier → human name, chip, and total RAM. The per-app
/// memory budget is DERIVED (see `AppleDeviceDatabase.estimatedAppMemoryBudgetGB`)
/// rather than stored, so one rule governs all devices.
public struct AppleDevice: Sendable, Equatable {
    public let identifier: String   // e.g. "iPhone16,1"
    public let name: String         // e.g. "iPhone 15 Pro"
    public let chip: AppleChip
    public let totalRAMGB: Double
}

/// Curated map of recent iPhones (A12 / 3 GB and up — the floor for a usable on-device
/// LLM). This is the "known-device intelligence" that makes picking reliable: iOS does
/// not expose total RAM via a public API, and `os_proc_available_memory()` only gives
/// the *current* headroom — the identifier tells us the device's ceiling.
public enum AppleDeviceDatabase {

    /// `hw.machine` identifier → device. Returns nil for Macs, simulators, and iPhones
    /// newer than this table (callers then fall back to a live RAM probe).
    public static func device(forIdentifier id: String) -> AppleDevice? {
        known[id]
    }

    public static let known: [String: AppleDevice] = {
        var m: [String: AppleDevice] = [:]
        func add(_ ids: [String], _ name: String, _ chip: AppleChip, _ ram: Double) {
            for id in ids { m[id] = AppleDevice(identifier: id, name: name, chip: chip, totalRAMGB: ram) }
        }
        // A12 (2018)
        add(["iPhone11,8"], "iPhone XR", .a12, 3)
        add(["iPhone11,2", "iPhone11,4", "iPhone11,6"], "iPhone XS", .a12, 4)
        // A13 (2019)
        add(["iPhone12,1"], "iPhone 11", .a13, 4)
        add(["iPhone12,3", "iPhone12,5"], "iPhone 11 Pro", .a13, 4)
        add(["iPhone12,8"], "iPhone SE (2nd gen)", .a13, 3)
        // A14 (2020)
        add(["iPhone13,1"], "iPhone 12 mini", .a14, 4)
        add(["iPhone13,2"], "iPhone 12", .a14, 4)
        add(["iPhone13,3"], "iPhone 12 Pro", .a14, 6)
        add(["iPhone13,4"], "iPhone 12 Pro Max", .a14, 6)
        // A15 (2021–2022)
        add(["iPhone14,4"], "iPhone 13 mini", .a15, 4)
        add(["iPhone14,5"], "iPhone 13", .a15, 4)
        add(["iPhone14,2"], "iPhone 13 Pro", .a15, 6)
        add(["iPhone14,3"], "iPhone 13 Pro Max", .a15, 6)
        add(["iPhone14,6"], "iPhone SE (3rd gen)", .a15, 4)
        add(["iPhone14,7"], "iPhone 14", .a15, 6)
        add(["iPhone14,8"], "iPhone 14 Plus", .a15, 6)
        // A16 (2022–2023)
        add(["iPhone15,2"], "iPhone 14 Pro", .a16, 6)
        add(["iPhone15,3"], "iPhone 14 Pro Max", .a16, 6)
        add(["iPhone15,4"], "iPhone 15", .a16, 6)
        add(["iPhone15,5"], "iPhone 15 Plus", .a16, 6)
        // A17 Pro (2023)
        add(["iPhone16,1"], "iPhone 15 Pro", .a17Pro, 8)
        add(["iPhone16,2"], "iPhone 15 Pro Max", .a17Pro, 8)
        // A18 / A18 Pro (2024)
        add(["iPhone17,3"], "iPhone 16", .a18, 8)
        add(["iPhone17,4"], "iPhone 16 Plus", .a18, 8)
        add(["iPhone17,1"], "iPhone 16 Pro", .a18Pro, 8)
        add(["iPhone17,2"], "iPhone 16 Pro Max", .a18Pro, 8)
        add(["iPhone17,5"], "iPhone 16e", .a18, 8)
        return m
    }()

    /// The per-app memory an LLM can realistically use before jetsam, as a fraction of
    /// total RAM. iOS kills apps well below total RAM; shipping the
    /// `com.apple.developer.kernel.increased-memory-limit` entitlement raises the
    /// ceiling, which a serious on-device LLM app must do. These fractions are
    /// conservative field estimates — the live profiler prefers the real
    /// `os_proc_available_memory()` when it can.
    public static func estimatedAppMemoryBudgetGB(
        totalRAMGB: Double,
        increasedMemoryLimitEntitlement: Bool = true
    ) -> Double {
        let fraction: Double
        switch totalRAMGB {
        case ..<3.5:  fraction = increasedMemoryLimitEntitlement ? 0.46 : 0.33  // 3 GB → ~1.4 / ~1.0
        case ..<5.5:  fraction = increasedMemoryLimitEntitlement ? 0.70 : 0.50  // 4 GB → ~2.8 / ~2.0
        case ..<7.5:  fraction = increasedMemoryLimitEntitlement ? 0.70 : 0.50  // 6 GB → ~4.2 / ~3.0
        default:      fraction = increasedMemoryLimitEntitlement ? 0.70 : 0.55  // 8 GB → ~5.6 / ~4.4
        }
        return (totalRAMGB * fraction * 10).rounded() / 10
    }
}
