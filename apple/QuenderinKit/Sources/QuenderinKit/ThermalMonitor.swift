import Foundation

/// The device's thermal pressure. On a phone, sustained inference (an agent loop) throttles on
/// HEAT long before memory — so the launcher reads this and sheds threads to stay sustainable.
public enum ThermalLevel: Sendable, Equatable {
    case nominal, fair, serious, critical
}

/// Reads the live OS thermal state. The OS → `ThermalLevel` mapping is split out so it's testable
/// without a hot device. Twin of Android `ThermalMonitor` (which maps `PowerManager` thermal status).
public enum ThermalMonitor {
    public static func currentLevel() -> ThermalLevel {
        level(from: ProcessInfo.processInfo.thermalState)
    }

    public static func level(from state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal:    return .nominal
        case .fair:       return .fair
        case .serious:    return .serious
        case .critical:   return .critical
        @unknown default: return .serious   // unknown → err toward caution (fewer threads)
        }
    }
}

/// Picks the inference thread count for a thermal level: drop threads as the device heats up so a
/// long generation doesn't throttle to a crawl (or get the app killed). Pure + testable.
/// Twin of Android `ThermalThrottle`.
public enum ThermalThrottle {
    public static func recommendedThreads(level: ThermalLevel, baseThreads: Int) -> Int {
        let base = max(1, baseThreads)
        switch level {
        case .nominal:  return base
        case .fair:     return max(1, base - 1)   // shed one core
        case .serious:  return max(1, base / 2)   // halve
        case .critical: return 1                  // single core — minimal heat
        }
    }
}

/// Re-tunes the thread count *during* a long generation as the thermal level moves — the load-time
/// snapshot only catches a phone that's already hot, but a 10-minute agent loop is what MAKES it
/// hot. The 4-level enum is its own hysteresis: re-tune only when the level changes AND the thread
/// count actually differs, so a sensor flapping at a boundary can't thrash `llama_set_n_threads`.
/// Pure state machine — the engine owns the sampling cadence and the native call. Twin of Android
/// `ThermalGovernor`.
public struct ThermalGovernor {
    public let baseThreads: Int
    public private(set) var currentLevel: ThermalLevel
    public private(set) var currentThreads: Int

    public init(baseThreads: Int, initialLevel: ThermalLevel) {
        let base = max(1, baseThreads)
        self.baseThreads = base
        self.currentLevel = initialLevel
        self.currentThreads = ThermalThrottle.recommendedThreads(level: initialLevel, baseThreads: base)
    }

    /// Feed a freshly-read level. Returns the new thread count to apply (via `llama_set_n_threads`)
    /// only when it should change; `nil` when nothing needs to change (same level, or same count).
    public mutating func update(level: ThermalLevel) -> Int? {
        guard level != currentLevel else { return nil }
        currentLevel = level
        let n = ThermalThrottle.recommendedThreads(level: level, baseThreads: baseThreads)
        guard n != currentThreads else { return nil }
        currentThreads = n
        return n
    }
}
