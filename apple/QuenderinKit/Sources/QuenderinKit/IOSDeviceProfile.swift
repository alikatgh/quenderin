import Foundation
#if os(iOS)
import os   // os_proc_available_memory()
#endif

/// Everything the iPhone model selector needs — richer than `HardwareProfile` because
/// on iOS the binding constraint is NOT total RAM but the per-app memory budget before
/// jetsam, and the chip (memory bandwidth) decides whether a model is usably fast.
public struct IOSDeviceProfile: Sendable, Equatable, Codable {
    public let deviceName: String
    public let identifier: String
    public let chip: AppleChip
    public let totalRAMGB: Double
    /// Memory an LLM can use before iOS jetsam-kills the app (GB). THE constraint.
    public let appMemoryBudgetGB: Double
    public let freeDiskGB: Double
    /// Battery capacity (mAh) — feeds the thermal/battery "what to expect" estimate.
    public let batteryMAh: Double
    /// True when `identifier` matched the curated device table (vs. a live-probe fallback).
    public let isKnownDevice: Bool

    public init(
        deviceName: String,
        identifier: String,
        chip: AppleChip,
        totalRAMGB: Double,
        appMemoryBudgetGB: Double,
        freeDiskGB: Double,
        batteryMAh: Double = AppleDeviceDatabase.fallbackBatteryMAh,
        isKnownDevice: Bool
    ) {
        self.deviceName = deviceName
        self.identifier = identifier
        self.chip = chip
        self.totalRAMGB = totalRAMGB
        self.appMemoryBudgetGB = appMemoryBudgetGB
        self.freeDiskGB = freeDiskGB
        self.batteryMAh = batteryMAh
        self.isKnownDevice = isKnownDevice
    }
}

/// Builds an `IOSDeviceProfile` for the running device. The selection LOGIC is pure and
/// lives in `IPhoneModelSelector`; this is the only impure part (sysctl + jetsam probe),
/// kept thin and seamed so the selector tests run on macOS with injected profiles.
public enum DeviceProfiler {

    public static func current() -> IOSDeviceProfile {
        let identifier = machineIdentifier()
        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        let freeDiskGB = Double(DiskSpace.availableBytes(at: documents)) / 1_000_000_000.0

        if let device = AppleDeviceDatabase.device(forIdentifier: identifier) {
            let budget = liveAppMemoryBudgetGB()
                ?? AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: device.totalRAMGB)
            return IOSDeviceProfile(
                deviceName: device.name,
                identifier: identifier,
                chip: device.chip,
                totalRAMGB: device.totalRAMGB,
                appMemoryBudgetGB: budget,
                freeDiskGB: freeDiskGB,
                batteryMAh: device.batteryMAh,
                isKnownDevice: true
            )
        }

        // Unknown identifier (a Mac, the Simulator, or an iPhone newer than the table):
        // fall back to probed total RAM + a conservative chip score.
        let hw = HardwareProbe.current()
        let budget = liveAppMemoryBudgetGB()
            ?? AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: hw.totalRAMGB)
        return IOSDeviceProfile(
            deviceName: hw.chip,
            identifier: identifier,
            chip: .unknown,
            totalRAMGB: hw.totalRAMGB,
            appMemoryBudgetGB: budget,
            freeDiskGB: freeDiskGB,
            isKnownDevice: false
        )
    }

    /// Real per-app headroom before jetsam, in GB. iOS-only; the rest of the world (and
    /// `swift test` on macOS) gets `nil` and falls back to the device-table estimate.
    /// This is the number that makes picking reliable on a busy device — validated on
    /// hardware (the on-device cliff).
    public static func liveAppMemoryBudgetGB() -> Double? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1_073_741_824.0 : nil
        #else
        return nil
        #endif
    }

    /// `hw.machine` — "iPhone16,1" on device. On the Simulator the real identifier is in
    /// `SIMULATOR_MODEL_IDENTIFIER`; on a Mac this is "arm64"/"x86_64" (→ unknown device).
    public static func machineIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        if let nul = buffer.firstIndex(of: 0) { buffer = Array(buffer[..<nul]) }
        let s = String(decoding: buffer, as: UTF8.self)
        return s.isEmpty ? "unknown" : s
    }
}
