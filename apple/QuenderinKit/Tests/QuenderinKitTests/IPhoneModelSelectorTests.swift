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
        // …and the selection SAYS the phone is full, not weak: what it would run with space.
        XCTAssertNotNil(sel.storageLimited)
    }

    /// 2026-09-05: the same 6 GB budget recommended Qwen3 4B one launch and Llama 3.2 1B the next
    /// (free disk had dropped) and the headline never mentioned storage. `storageLimited` is the
    /// model the phone WOULD get with space — nil whenever disk didn't change the answer.
    func testStorageLimitedNamesWhatFreeSpaceWouldUnlock() {
        let roomy = IPhoneModelSelector.select(for: profile(chip: .a17Pro, ram: 8, disk: 128))
        XCTAssertNil(roomy.storageLimited, "plenty of disk → storage didn't decide anything")

        let full = IPhoneModelSelector.select(for: profile(chip: .a17Pro, ram: 8, disk: 2.0))
        XCTAssertEqual(full.model.id, "llama32-1b", "~2 GB free fits only the 0.8 GB download (+0.5 margin)")
        let limited = try! XCTUnwrap(full.storageLimited)
        XCTAssertEqual(limited.model.id, roomy.model.id, "names exactly the pick an unlimited disk would give")
        XCTAssertFalse(limited.viable)
        XCTAssertTrue(limited.note.contains("free disk"), "gated by disk, not memory or speed: \(limited.note)")
        // The picker's memory badge still says it FITS — storage is the only thing in the way.
        XCTAssertTrue(IPhoneModelSelector.fitness(of: limited.model, for: profile(chip: .a17Pro, ram: 8, disk: 2.0)).canLoad)
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

    func testUnsupportedWhenEvenSmallestModelCantFit() {
        // Almost no app-memory budget — even the smallest model won't fit → unsupported, not forced.
        let device = IOSDeviceProfile(
            deviceName: "Ancient", identifier: "z", chip: .a12, totalRAMGB: 1,
            appMemoryBudgetGB: 0.2, freeDiskGB: 32, isKnownDevice: false
        )
        XCTAssertEqual(IPhoneModelSelector.select(for: device).confidence, .unsupported)
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

    // MARK: - The picker must agree with the recommendation (2026-09-05 regression)

    /// The "Choose a model" screen used to re-gate on TOTAL RAM (`MemoryFitness.check`), so one tap
    /// after onboarding recommended Qwen3 4B for an 8 GB iPhone it crowned Qwen3 14B "recommended for
    /// this phone". Pin: the picker's per-row fitness is the selector's own memory gate.
    func testPickerFitnessAgreesWithTheRecommendation() {
        let device = knownProfile("iPhone16,1")   // iPhone 15 Pro, 8 GB — a ~6 GB app budget
        let sel = IPhoneModelSelector.select(for: device)

        // The recommended model must load by the picker's gate.
        XCTAssertTrue(IPhoneModelSelector.fitness(of: sel.model, for: device).canLoad)
        // 14B (~11 GB) can never fit an 8 GB phone's jetsam budget — the exact row the old gate crowned.
        let big = ModelCatalog.entry(id: "qwen3-14b")!
        XCTAssertFalse(IPhoneModelSelector.fitness(of: big, for: device).canLoad)
        // Every alternative the selector rejected FOR MEMORY is blocked by the picker too, and every
        // viable alternative loads — the two screens reason from one gate.
        for option in sel.alternatives {
            let fit = IPhoneModelSelector.fitness(of: option.model, for: device)
            if option.note.contains("usable budget") {
                XCTAssertFalse(fit.canLoad, "\(option.model.id) is over budget yet the picker says it fits")
            } else if option.viable {
                XCTAssertTrue(fit.canLoad, "\(option.model.id) is viable yet the picker blocks it")
            }
        }
        // The picker shows the whole catalog, and its numbers are the selector's (usable budget, runtime).
        let options = ModelCatalog.optionsWithFitness(for: device)
        XCTAssertEqual(options.count, ModelCatalog.models.count)
        let usable = device.appMemoryBudgetGB * IPhoneModelSelector.memoryHeadroom
        for option in options {
            XCTAssertEqual(option.fitness.availableMemoryGB, usable, accuracy: 1e-9)
            XCTAssertEqual(option.fitness.requiredMemoryGB, IPhoneModelSelector.estimatedRuntimeGB(option.model), accuracy: 1e-9)
        }
        // Comfort headroom ⇔ "Fits"; less than that ⇔ "Tight"; over budget ⇔ "Too big".
        for option in options {
            let remaining = usable - option.fitness.requiredMemoryGB
            let expected: MemorySeverity = !option.fitness.canLoad ? .blocked
                : (remaining >= option.fitness.requiredMemoryGB * IPhoneModelSelector.comfortHeadroomFraction ? .safe : .warning)
            XCTAssertEqual(option.fitness.severity, expected, option.model.id)
        }
    }
}
