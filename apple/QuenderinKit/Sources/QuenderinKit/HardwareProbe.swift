import Foundation

/// What we can learn about the device before deciding which modules to fetch.
public struct HardwareProfile: Sendable, Equatable {
    public let totalRAMGB: Double
    public let processorCount: Int
    public let chip: String
    public let isAppleSilicon: Bool
}

/// Probes the running device. Pure Foundation/Darwin sysctl — works on both
/// macOS (for tests/desktop parity) and iOS (the real target).
public enum HardwareProbe {

    public static func current() -> HardwareProfile {
        let info = ProcessInfo.processInfo
        let totalRAMGB = Double(info.physicalMemory) / 1_073_741_824.0  // 1024^3
        let chip = sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? sysctlString("hw.machine")
            ?? "Unknown"
        // arm64 == Apple Silicon (Mac) and every modern iOS device.
        let isAppleSilicon = (sysctlInt("hw.optional.arm64") ?? 0) == 1

        return HardwareProfile(
            totalRAMGB: totalRAMGB,
            processorCount: info.processorCount,
            chip: chip,
            isAppleSilicon: isAppleSilicon
        )
    }

    /// Logical performance-core count (Apple Silicon exposes its P-core cluster as `perflevel0`).
    /// `nil` on devices/Macs where the key is absent — the caller falls back to a heuristic.
    public static func performanceCoreCount() -> Int? {
        if let p = sysctlInt("hw.perflevel0.logicalcpu"), p > 0 { return p }
        return nil
    }

    // MARK: - sysctl helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl strings are NUL-terminated; drop the terminator before decoding.
        if let nul = buffer.firstIndex(of: 0) {
            buffer = Array(buffer[..<nul])
        }
        let result = String(decoding: buffer, as: UTF8.self)
        return result.isEmpty ? nil : result
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
