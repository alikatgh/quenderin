import XCTest
@testable import QuenderinKit

/// The world-class iPhone picker: jetsam-budget + chip + disk aware, with explainable
/// results. These tests pin the product intent for real devices.
final class IPhoneModelSelectorTests: XCTestCase {

    // MARK: - Helpers

    private func knownProfile(_ identifier: String, disk: Double = 128) -> IOSDeviceProfile {
        let d = AppleDeviceDatabase.device(forIdentifier: identifier)!
        return IOSDeviceProfile(
            deviceName: d.name, identifier: identifier, chip: d.chip, totalRAMGB: d.totalRAMGB,
            appMemoryBudgetGB: AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: d.totalRAMGB),
            freeDiskGB: disk, batteryMAh: d.batteryMAh, isKnownDevice: true
        )
    }

    private func profile(chip: AppleChip, ram: Double, disk: Double = 128) -> IOSDeviceProfile {
        IOSDeviceProfile(
            deviceName: "Test", identifier: "test", chip: chip, totalRAMGB: ram,
            appMemoryBudgetGB: AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: ram),
            freeDiskGB: disk, isKnownDevice: false
        )
    }

    // MARK: - Real-device picks (the product spec)

    func testKnownIPhonePicks() {
        let cases: [(id: String, name: String, expected: String)] = [
            ("iPhone11,8", "iPhone XR",            "llama32-1b"),   // A12, 3 GB
            ("iPhone11,2", "iPhone XS",            "llama32-1b"),   // A12, 4 GB → perf-gated down
            ("iPhone12,8", "iPhone SE (2nd gen)",  "llama32-1b"),   // A13, 3 GB
            ("iPhone13,2", "iPhone 12",            "llama32-1b"),   // A14, 4 GB → 3B exceeds the ~2.1 GB jetsam budget
            ("iPhone14,5", "iPhone 13",            "llama32-1b"),   // A15, 4 GB → same; live os_proc_available_memory may upgrade
            ("iPhone14,2", "iPhone 13 Pro",        "qwen3-4b"),     // A15, 6 GB
            ("iPhone15,4", "iPhone 15",            "qwen3-4b"),     // A16, 6 GB
            ("iPhone16,1", "iPhone 15 Pro",        "qwen3-4b"),     // A17 Pro, 8 GB
            ("iPhone17,1", "iPhone 16 Pro",        "qwen3-4b"),     // A18 Pro, 8 GB
        ]
        for c in cases {
            let sel = IPhoneModelSelector.select(for: knownProfile(c.id))
            XCTAssertEqual(sel.device.deviceName, c.name)
            XCTAssertEqual(sel.model.id, c.expected, "\(c.name): expected \(c.expected), got \(sel.model.id)")
        }
    }

    /// The headline property: a model can fit TOTAL RAM yet exceed the per-app jetsam
    /// budget — picking it would get the app killed. The selector must refuse it, where
    /// the naive RAM-band recommender would not.
    func testJetsamBudgetPreventsOverpick() {
        // Reports 12 GB total RAM but only ~5 GB usable before jetsam.
        let device = IOSDeviceProfile(
            deviceName: "Constrained", identifier: "x", chip: .a18Pro, totalRAMGB: 12,
            appMemoryBudgetGB: 5.0, freeDiskGB: 128, isKnownDevice: true
        )
        let sel = IPhoneModelSelector.select(for: device)
        // Naive total-RAM logic would pick the 14B (≥10 GB band):
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 12), "qwen3-14b")
        // The jetsam-aware selector must not:
        XCTAssertNotEqual(sel.model.id, "qwen3-14b")
        XCTAssertEqual(sel.model.id, "qwen3-4b")
    }

    /// Same RAM, different chip → different pick. RAM-only logic can't do this.
    func testSameRAMDifferentChipDiffers() {
        // Same 6 GB: a fast A16 earns the 4B; a hypothetical A12 is perf-gated down to 1B
        // even though the 4B fits its memory.
        XCTAssertEqual(IPhoneModelSelector.select(for: profile(chip: .a16, ram: 6)).model.id, "qwen3-4b")
        XCTAssertEqual(IPhoneModelSelector.select(for: profile(chip: .a12, ram: 6)).model.id, "llama32-1b")
    }

    /// The advisory heat/battery estimate is attached and sane.
    func testThermalBatteryEstimateIsSane() {
        let sel = IPhoneModelSelector.select(for: knownProfile("iPhone16,1")) // 15 Pro → Qwen3 4B
        let tb = sel.thermalBattery
        XCTAssertEqual(tb.mAhPer1KTokens, 20, accuracy: 0.01, "4B ≈ 5 mAh/1k tokens × 4")
        XCTAssertGreaterThan(tb.activeDrainPercentPerHour, 0)
        XCTAssertLessThan(tb.activeDrainPercentPerHour, 100, "continuous drain is a sane %/hr")
        XCTAssertLessThan(tb.sustainedTokensPerSecond, sel.estimatedTokensPerSecond, "throttled < peak")
        XCTAssertTrue(tb.chatVerdict.lowercased().contains("light"))
        XCTAssertTrue(tb.sustainedVerdict.contains("%/hr"))
    }

    // MARK: - Gates

    func testDiskConstraintForcesSmaller() {
        let sel = IPhoneModelSelector.select(for: profile(chip: .a17Pro, ram: 8, disk: 1.0))
        XCTAssertEqual(sel.model.id, "llama32-1b-q2", "only the tiniest GGUF fits ~1 GB free")
    }

    func testVeryConstrainedDeviceFallsBackToSmallestWithForcedConfidence() {
        // 2 GB device, tiny budget — nothing in the general set clears the gates cleanly.
        let device = IOSDeviceProfile(
            deviceName: "Old", identifier: "y", chip: .a12, totalRAMGB: 2,
            appMemoryBudgetGB: 0.8, freeDiskGB: 64, isKnownDevice: false
        )
        let sel = IPhoneModelSelector.select(for: device)
        XCTAssertEqual(sel.model.id, ModelCatalog.smallest.id)
        XCTAssertEqual(sel.confidence, .forced)
    }

    // MARK: - Estimators

    func testRuntimeAndSpeedAreMonotonic() {
        let b1 = ModelCatalog.entry(id: "llama32-1b")!
        let b4 = ModelCatalog.entry(id: "qwen3-4b")!
        let b14 = ModelCatalog.entry(id: "qwen3-14b")!
        XCTAssertLessThan(IPhoneModelSelector.estimatedRuntimeGB(b1), IPhoneModelSelector.estimatedRuntimeGB(b4))
        XCTAssertLessThan(IPhoneModelSelector.estimatedRuntimeGB(b4), IPhoneModelSelector.estimatedRuntimeGB(b14))
        XCTAssertGreaterThan(
            IPhoneModelSelector.estimatedTokensPerSecond(b1, chip: .a18Pro),
            IPhoneModelSelector.estimatedTokensPerSecond(b4, chip: .a18Pro)
        )
        // Same model is faster on a newer chip.
        XCTAssertGreaterThan(
            IPhoneModelSelector.estimatedTokensPerSecond(b4, chip: .a18Pro),
            IPhoneModelSelector.estimatedTokensPerSecond(b4, chip: .a13)
        )
    }

    // MARK: - Explainability

    func testRationaleAndAlternatives() {
        let sel = IPhoneModelSelector.select(for: knownProfile("iPhone16,1"))
        XCTAssertTrue(sel.rationale.contains("iPhone 15 Pro"), "rationale names the device")
        XCTAssertTrue(sel.rationale.contains("tok/s"), "rationale states estimated speed")
        XCTAssertFalse(sel.alternatives.isEmpty, "bigger gated models are surfaced")
        XCTAssertTrue(sel.alternatives.contains { $0.model.id == "qwen3-14b" && !$0.viable })
        XCTAssertGreaterThan(sel.memoryHeadroomGB, 0)
    }

    func testSpecializedModelsSurfaceOnRoomyHardware() {
        // An iPad/Mac-class profile with a big budget: 7B specialized models become viable
        // and appear as opt-in alternatives (never the silent default).
        let device = IOSDeviceProfile(
            deviceName: "iPad-class", identifier: "iPad", chip: .mSeries, totalRAMGB: 16,
            appMemoryBudgetGB: 11.0, freeDiskGB: 256, isKnownDevice: false
        )
        let sel = IPhoneModelSelector.select(for: device)
        XCTAssertFalse(IPhoneModelSelector.specializedNotes.keys.contains(sel.model.id),
                       "default is general-purpose, not a specialized model")
        XCTAssertTrue(sel.alternatives.contains { $0.model.id == "qwen25-coder-7b" && $0.viable },
                      "the coder model is offered when it fits")
    }
}
