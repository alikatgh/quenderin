import Foundation

/// How sure we are about a pick — drives whether the UI says "great fit" vs. "this is
/// tight" vs. "your device is very constrained".
public enum SelectionConfidence: String, Sendable, Codable {
    case comfortable   // clears every gate with healthy headroom
    case tight         // viable, but close on memory or speed
    case forced        // nothing ideal cleared the gates; using the smallest model
}

/// A model considered during selection, with why it was (or wasn't) chosen.
public struct ModelOption: Sendable, Equatable, Codable {
    public let model: ModelEntry
    public let viable: Bool
    public let estimatedTokensPerSecond: Double
    public let estimatedRuntimeGB: Double
    public let note: String
}

/// The result of picking a model for an iPhone — the choice plus a human rationale and
/// the alternatives a power user might want.
public struct ModelSelection: Sendable, Equatable, Codable {
    public let model: ModelEntry
    public let estimatedTokensPerSecond: Double
    public let estimatedRuntimeGB: Double
    public let appMemoryBudgetGB: Double
    public let usableMemoryGB: Double
    public let memoryHeadroomGB: Double
    /// What to expect for heat and battery (advisory — not a selection gate).
    public let thermalBattery: ThermalBatteryEstimate
    public let confidence: SelectionConfidence
    public let rationale: String
    public let device: IOSDeviceProfile
    public let alternatives: [ModelOption]
}

/// World-class on-device model picking for iPhones. A RAM-band heuristic is wrong here:
/// iOS jetsam-kills an app well below total RAM, and chip bandwidth — not capacity —
/// decides whether generation feels alive. This gates every candidate on THREE realities
/// and explains the result:
///
///   1. **Jetsam memory budget** — the per-app limit before iOS kills the app, NOT total RAM.
///   2. **Chip throughput** — will it generate tokens fast enough to feel responsive?
///   3. **Disk** — does the GGUF actually fit, with margin?
///
/// It defaults to the best GENERAL-PURPOSE model clearing all three, and surfaces
/// bigger/just-missed and specialized models as transparent alternatives. Pure logic on
/// an injected `IOSDeviceProfile`, so every pick is unit-tested for real iPhones.
public enum IPhoneModelSelector {

    /// Use at most this share of the jetsam budget — headroom for the OS and a margin
    /// against being killed mid-generation.
    public static let memoryHeadroom = 0.85
    /// Below this, chat feels laggy; a model that fits but crawls is the wrong pick.
    public static let minTokensPerSecond = 7.0
    /// The DEFAULT prefers the largest model that's *comfortable* — snappy and with real
    /// memory headroom — over a bigger one that merely fits (offered as an alternative).
    public static let comfortTokensPerSecond = 8.0
    public static let comfortHeadroomFraction = 0.25
    public static let referenceContextTokens = 4096
    /// Keep this much free disk beyond the download (KV spill, OS breathing room).
    public static let diskMarginGB = 0.5

    /// General-purpose models, best → smallest. The DEFAULT pick is the first of these
    /// that clears the gates (so a 4B tier resolves to Qwen3 4B, not a same-size
    /// sibling), matching the desktop band recommender's intent. Specialized models are
    /// never auto-selected — only offered.
    public static let defaultPreferenceIDs = [
        "qwen3-14b", "llama3-8b", "mistral-7b", "qwen3-4b",
        "gemma3-4b", "phi4-mini", "llama32-3b", "llama32-1b", "llama32-1b-q2",
    ]
    /// Task-specific models — strong picks, but not a sensible silent default.
    public static let specializedNotes: [String: String] = [
        "qwen25-coder-7b": "better for coding & tool use",
        "deepseek-r1-7b": "better for step-by-step reasoning",
    ]

    // MARK: - Estimators (pure, individually unit-testable)

    /// Quantized-weight size (GB): params × bits-per-weight ÷ 8.
    public static func weightsGB(_ model: ModelEntry) -> Double {
        let bits = Quantization.info(id: model.quantization)?.bitsPerWeight ?? 4.5
        return model.paramsBillions * bits / 8.0
    }

    /// Peak runtime footprint (GB): weights + activation buffers + KV cache + base.
    /// Heuristic — refine against real device telemetry (the on-device cliff).
    public static func estimatedRuntimeGB(
        _ model: ModelEntry,
        contextTokens: Int = referenceContextTokens
    ) -> Double {
        let w = weightsGB(model)
        let activations = w * 0.10
        let kvCache = Double(contextTokens) / 4096.0 * (0.10 + 0.03 * model.paramsBillions)
        let base = 0.25
        return w + activations + kvCache + base
    }

    /// Estimated stock-llama.cpp decode speed (tokens/sec): a reference rate on the A18
    /// Pro (score 1.0), scaled by the chip's relative score. Calibrated so the reference
    /// reproduces measured 1B-Q4 rates (A14 ≈ 15, A16 ≈ 20 tok/s). Decode is
    /// memory-bandwidth bound, so this tracks bandwidth, not FLOPS; an optimized engine
    /// or GPU/NPU decode path could roughly double it.
    public static func estimatedTokensPerSecond(_ model: ModelEntry, chip: AppleChip) -> Double {
        let referenceOnA18Pro = 75.0 / (model.paramsBillions + 1.7)
        return referenceOnA18Pro * chip.inferenceScore
    }

    public static func estimatedDownloadGB(_ model: ModelEntry) -> Double {
        Double(DiskSpace.estimatedDownloadBytes(for: model)) / 1_000_000_000.0
    }

    // MARK: - Selection

    public static func select(
        for device: IOSDeviceProfile,
        catalog: [ModelEntry] = ModelCatalog.models,
        minTokensPerSecond: Double = minTokensPerSecond
    ) -> ModelSelection {
        let usableGB = device.appMemoryBudgetGB * memoryHeadroom

        func evaluate(_ model: ModelEntry) -> ModelOption {
            let runtime = estimatedRuntimeGB(model)
            let tokS = estimatedTokensPerSecond(model, chip: device.chip)
            let download = estimatedDownloadGB(model)
            let fitsMemory = runtime <= usableGB
            let fastEnough = tokS >= minTokensPerSecond
            let fitsDisk = device.freeDiskGB >= download + diskMarginGB
            let viable = fitsMemory && fastEnough && fitsDisk
            let note: String
            if !fitsMemory {
                note = String(format: "needs ~%.1f GB, over your ~%.1f GB usable budget", runtime, usableGB)
            } else if !fastEnough {
                note = String(format: "~%.0f tok/s on the %@ — too slow", tokS, device.chip.displayName)
            } else if !fitsDisk {
                note = String(format: "needs ~%.1f GB free disk", download + diskMarginGB)
            } else {
                note = String(format: "~%.0f tok/s, uses ~%.1f GB", tokS, runtime)
            }
            return ModelOption(
                model: model, viable: viable,
                estimatedTokensPerSecond: tokS, estimatedRuntimeGB: runtime, note: note
            )
        }

        // Evaluate every general-purpose candidate (preference order = best → smallest).
        let candidates = defaultPreferenceIDs.compactMap { id in catalog.first { $0.id == id } }
        let options = candidates.map(evaluate)

        func isComfortable(_ o: ModelOption) -> Bool {
            o.viable
                && (usableGB - o.estimatedRuntimeGB) >= o.estimatedRuntimeGB * comfortHeadroomFraction
                && o.estimatedTokensPerSecond >= comfortTokensPerSecond
        }

        // Prefer the largest COMFORTABLE model (snappy + real headroom) over a bigger one
        // that merely fits — the bigger/tight ones become transparent alternatives.
        let pickIndex = options.firstIndex(where: isComfortable) ?? options.firstIndex(where: { $0.viable })

        // Specialized models that WOULD fit → opt-in suggestions (never auto-picked).
        let specialized: [ModelOption] = specializedNotes.keys.sorted().compactMap { id in
            guard let model = catalog.first(where: { $0.id == id }) else { return nil }
            let option = evaluate(model)
            guard option.viable else { return nil }
            let why = specializedNotes[id] ?? ""
            return ModelOption(
                model: model, viable: true,
                estimatedTokensPerSecond: option.estimatedTokensPerSecond,
                estimatedRuntimeGB: option.estimatedRuntimeGB,
                note: "\(why) · \(option.note)"
            )
        }

        guard let idx = pickIndex else {
            // Nothing cleared the gates — fall back to the smallest model, honestly labeled.
            let sm = ModelCatalog.smallest
            let runtime = estimatedRuntimeGB(sm)
            let tokS = estimatedTokensPerSecond(sm, chip: device.chip)
            return ModelSelection(
                model: sm,
                estimatedTokensPerSecond: tokS,
                estimatedRuntimeGB: runtime,
                appMemoryBudgetGB: device.appMemoryBudgetGB,
                usableMemoryGB: usableGB,
                memoryHeadroomGB: max(0.0, usableGB - runtime),  // clamp: negative headroom is meaningless (forced path)
                thermalBattery: ThermalBattery.estimate(for: sm, chip: device.chip, batteryMAh: device.batteryMAh, peakTokensPerSecond: tokS),
                confidence: .forced,
                rationale: "\(device.deviceName) is very memory-constrained (~\(fmt(usableGB)) GB usable). "
                    + "Using the smallest model, \(sm.label), so it stays responsive and is never jetsam-killed.",
                device: device,
                alternatives: options   // everything considered, for transparency
            )
        }

        let pick = options[idx]
        let biggerGated = Array(options.prefix(idx))   // models ahead of the pick → alternatives
        let headroom = usableGB - pick.estimatedRuntimeGB
        let comfortable = isComfortable(pick)
        let speedWord = pick.estimatedTokensPerSecond >= 15 ? "comfortably"
            : (pick.estimatedTokensPerSecond >= 9 ? "smoothly" : "usably")
        let rationale = String(
            format: "%@ for your %@: ~%.0f tok/s on the %@ (%@), using ~%.1f GB of your ~%.1f GB app-memory budget (%.1f GB headroom).",
            pick.model.label, device.deviceName, pick.estimatedTokensPerSecond,
            device.chip.displayName, speedWord, pick.estimatedRuntimeGB, device.appMemoryBudgetGB, headroom
        )

        return ModelSelection(
            model: pick.model,
            estimatedTokensPerSecond: pick.estimatedTokensPerSecond,
            estimatedRuntimeGB: pick.estimatedRuntimeGB,
            appMemoryBudgetGB: device.appMemoryBudgetGB,
            usableMemoryGB: usableGB,
            memoryHeadroomGB: headroom,
            thermalBattery: ThermalBattery.estimate(for: pick.model, chip: device.chip, batteryMAh: device.batteryMAh, peakTokensPerSecond: pick.estimatedTokensPerSecond),
            confidence: comfortable ? .comfortable : .tight,
            rationale: rationale,
            device: device,
            alternatives: biggerGated + specialized
        )
    }

    /// Convenience: pick for the running device.
    public static func selectForThisDevice() -> ModelSelection {
        select(for: DeviceProfiler.current())
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
