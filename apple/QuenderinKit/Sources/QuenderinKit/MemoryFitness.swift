import Foundation

public enum MemorySeverity: String, Sendable, Codable {
    case safe, warning, critical, blocked
}

/// Whether a given model can be loaded on a device with a given memory budget.
/// Mirrors `MemoryCheckResult` / `checkMemoryForModel` in the desktop app.
public struct MemoryCheckResult: Sendable, Equatable {
    public let canLoad: Bool
    public let severity: MemorySeverity
    public let availableMemoryGB: Double
    public let requiredMemoryGB: Double
    public let remainingAfterLoadGB: Double
    public let message: String
}

public enum MemoryFitness {
    /// 85% of total = hard block, 65% = warning. Ported from the desktop budgets.
    public static let defaultBudgetHard = 0.85
    public static let defaultBudgetWarning = 0.65
    /// Overhead scales with model size — smaller models need less KV-cache headroom.
    public static let overheadBase = 1.15
    public static let overheadLarge = 1.30

    /// Pure, deterministic check — pass in totals so it is testable without
    /// touching real hardware. `check(for:)` below wraps the live device.
    public static func check(
        model: ModelEntry,
        totalGB: Double,
        freeGB: Double,
        budgetHard: Double = defaultBudgetHard,
        budgetWarning: Double = defaultBudgetWarning
    ) -> MemoryCheckResult {
        let overhead = model.paramsBillions <= 3 ? overheadBase : overheadLarge
        let required = model.ramGB * overhead
        let remaining = freeGB - required
        let usageAfterLoad = (totalGB - freeGB + required) / totalGB

        if usageAfterLoad > budgetHard {
            return MemoryCheckResult(
                canLoad: false,
                severity: .blocked,
                availableMemoryGB: freeGB,
                requiredMemoryGB: required,
                remainingAfterLoadGB: remaining,
                message: "Loading \(model.label) needs ~\(fmt(required))GB but only \(fmt(freeGB))GB is free. Close some apps or choose a smaller model."
            )
        }
        if usageAfterLoad > budgetWarning {
            return MemoryCheckResult(
                canLoad: true,
                severity: .warning,
                availableMemoryGB: freeGB,
                requiredMemoryGB: required,
                remainingAfterLoadGB: remaining,
                message: "\(model.label) will leave only \(fmt(remaining))GB free. System may be slow."
            )
        }
        return MemoryCheckResult(
            canLoad: true,
            severity: .safe,
            availableMemoryGB: freeGB,
            requiredMemoryGB: required,
            remainingAfterLoadGB: remaining,
            message: "\(model.label) fits comfortably."
        )
    }

    /// Live check against the current device. On iOS, free memory is not reliably
    /// exposed, so we conservatively treat total physical RAM as the budget.
    public static func check(for model: ModelEntry) -> MemoryCheckResult {
        let total = HardwareProbe.current().totalRAMGB
        return check(model: model, totalGB: total, freeGB: total)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
