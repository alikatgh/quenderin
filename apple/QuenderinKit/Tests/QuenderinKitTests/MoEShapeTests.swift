import XCTest
@testable import QuenderinKit

/// The paged-MoE path end to end: name detection → resident-set estimate → search fitness →
/// GPU-offload decision → curated catalog entry. Grounded in the measured reality this ships on:
/// a 13 GB Qwen3.x-35B-A3B runs at 17.3 tok/s on a 16 GB M4 with 4–6 GB resident, CPU-only,
/// experts streamed by the OS page cache (modelfit.io benchmark; llama.cpp #19163).
final class MoEShapeTests: XCTestCase {

    // MARK: detection

    func testDetectsTheReleasedNamingConvention() {
        let q36 = MoEShape.detect("unsloth/Qwen3.6-35B-A3B-GGUF Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf")
        XCTAssertEqual(q36, MoEShape(totalParamsB: 35, activeParamsB: 3))
        XCTAssertEqual(MoEShape.detect("Qwen3-30B-A3B-Q4_K_M"), MoEShape(totalParamsB: 30, activeParamsB: 3))
        XCTAssertEqual(MoEShape.detect("qwen3-235b-a22b"), MoEShape(totalParamsB: 235, activeParamsB: 22))
    }

    func testDenseAndDegenerateNamesAreNotMoE() {
        XCTAssertNil(MoEShape.detect("Qwen/Qwen3-14B-GGUF"))          // dense
        XCTAssertNil(MoEShape.detect("llama-3.2-1b-instruct"))        // dense
        XCTAssertNil(MoEShape.detect("weird-3b-a35b"))                // active > total: nonsense
        XCTAssertNil(MoEShape.detect("mixtral-8x7b-instruct"))        // different convention — stays dense-estimated
    }

    // MARK: resident-set estimate

    func testPagedResidentIsTheSpineNotTheFile() {
        // 12.3 GiB file (the real 35B-A3B IQ3_XXS): resident lands in the measured 4–6 GB band,
        // a third of the dense estimate (which would wrongly block a 16 GB machine).
        let shape = MoEShape(totalParamsB: 35, activeParamsB: 3)
        let resident = MoEShape.pagedResidentRamGB(fileSizeGB: 12.3, shape: shape)
        XCTAssertEqual(resident, 5.04, accuracy: 0.1)
        XCTAssertLessThan(resident, (12.3 * 1.5 + 0.3) / 3.0)
    }

    func testFatActiveMoEClampsToTheDenseEstimate() {
        // active ≈ total → paging buys nothing; never estimate BELOW dense reality.
        let fat = MoEShape(totalParamsB: 10, activeParamsB: 9)
        let resident = MoEShape.pagedResidentRamGB(fileSizeGB: 10, shape: fat)
        XCTAssertEqual(resident, 10 * 1.5 + 0.3, accuracy: 0.001)
    }

    // MARK: search plumbing

    func testEstimatedParamsReadsTotalNotActive() {
        // The last-B-token rule alone would read "…-A3B" as a 3B model.
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("Qwen3.6-35B-A3B-GGUF"), 35)
    }

    func testCandidateBudgetsPagedResidentForMoE() {
        let bytes13GB = 13_211_155_424               // real HF size of the 35B-A3B IQ3_XXS
        let moe = HFQuant(repo: "unsloth/Qwen3.6-35B-A3B-GGUF",
                          filename: "Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf",
                          sizeBytes: bytes13GB, sha256: nil)
        let entry = HuggingFaceCatalog.candidate(from: moe, label: "test")
        XCTAssertLessThan(entry.ramGB, 6.0, "paged MoE budgets its resident set")
        XCTAssertEqual(entry.paramsBillions, 35)
        // Dense control: same size, dense name → the old formula.
        let dense = HFQuant(repo: "some/dense-13b", filename: "dense-13b-Q8_0.gguf",
                            sizeBytes: bytes13GB, sha256: nil)
        let denseEntry = HuggingFaceCatalog.candidate(from: dense, label: "test")
        XCTAssertEqual(denseEntry.ramGB, dense.sizeGB * 1.5 + 0.3, accuracy: 0.001)
    }

    func testFiltersGateMoEByActiveClassButDownloadByTotal() {
        let hit = HFModelHit(id: "unsloth/Qwen3.6-35B-A3B-GGUF", downloads: 9999, gated: false)
        // A params cap of 4B admits the 35B MoE — per token it IS a 3B-class load…
        let paramsCapped = ModelSearchFilters(maxParamsB: 4)
        XCTAssertEqual(paramsCapped.apply(to: [hit], totalRAMGB: 16).count, 1)
        // …but "small and fast" still hides it: its ~19 GB assumed-Q4 download busts that cap.
        XCTAssertEqual(ModelSearchFilters.smallAndFast.apply(to: [hit], totalRAMGB: 16).count, 0)
        // fitsOnly: visible on 16 GB (resident ~8 GB rough), hidden on 8 GB (spine starves it).
        let fits = ModelSearchFilters(fitsOnly: true)
        XCTAssertEqual(fits.apply(to: [hit], totalRAMGB: 16).count, 1)
        XCTAssertEqual(fits.apply(to: [hit], totalRAMGB: 8).count, 0)
    }

    func testBestICanRunAdmitsThePagedMoEDownload() {
        XCTAssertEqual(ModelSearchFilters.bestICanRun.maxDownloadGB, 14,
                       "the 13.2 GB 35B-A3B IQ3 is exactly the 'best I can run' answer on 16 GB")
    }

    // MARK: GPU offload policy

    func testOffloadsAllLayersWhenWeightsFitTheBudget() {
        XCTAssertEqual(GpuOffloadPolicy.nGpuLayers(fileSizeGB: 9.0, deviceBudgetGB: 11.2), 999)
        XCTAssertEqual(GpuOffloadPolicy.nGpuLayers(fileSizeGB: 13.2, deviceBudgetGB: 24.0), 999)
    }

    func testGoesCpuOnlyWhenWeightsExceedTheBudget() {
        // The verified paged-MoE configuration: 13 GB file on a 16 GB Mac (~11 GB budget).
        XCTAssertEqual(GpuOffloadPolicy.nGpuLayers(fileSizeGB: 13.2, deviceBudgetGB: 11.2), 0)
        XCTAssertEqual(GpuOffloadPolicy.nGpuLayers(fileSizeGB: 0.0, deviceBudgetGB: 4.0), 999,
                       "missing/stat-failed size (0) must not disable Metal")
    }

    // MARK: curated catalog entry

    func testCuratedMoEEntryFitness() {
        let moe = ModelCatalog.entry(id: "qwen36-35b-a3b")
        XCTAssertNotNil(moe)
        guard let moe else { return }
        XCTAssertEqual(moe.quantization, "UD-IQ3_XXS")
        // 16 GB: safe. 8 GB: blocked — the resident spine + KV genuinely starve it.
        XCTAssertEqual(MemoryFitness.check(model: moe, totalGB: 16, freeGB: 16).severity, .safe)
        XCTAssertFalse(MemoryFitness.check(model: moe, totalGB: 8, freeGB: 8).canLoad)
        // Download estimate must reflect the real 13.2 GB file, not a 4.5-bit fallback (19.7).
        let estGB = Double(DiskSpace.estimatedDownloadBytes(for: moe)) / 1_000_000_000.0
        XCTAssertEqual(estGB, 13.2, accuracy: 0.3)
    }

    func testMoEUpgradeOfferIsHonestOn16GBAndYieldsTo14BOn32() {
        XCTAssertEqual(AgentModelGuide.aptitude(for: "qwen36-35b-a3b"), .excellent)
        // 16 GB: the 85% budget blocks the 14B, so the MoE is the honest best — offered
        // with the dedicated paged-MoE copy (13 GB download, SSD-streamed), not the generic line.
        let on16 = AgentModelGuide.briefing(activeModelID: "qwen3-4b", totalRAMGB: 16, deviceNoun: "Mac")
        XCTAssertEqual(on16.upgrade?.modelLabel, ModelCatalog.entry(id: "qwen36-35b-a3b")?.label)
        XCTAssertTrue(on16.upgrade?.reason.contains("13 GB download") == true)
        XCTAssertTrue(on16.upgrade?.reason.contains("SSD") == true)
        // 32 GB: both fit → agentRank's params nudge prefers the 14B (dense, no giant download).
        let on32 = AgentModelGuide.briefing(activeModelID: "qwen3-4b", totalRAMGB: 32, deviceNoun: "Mac")
        XCTAssertEqual(on32.upgrade?.modelLabel, ModelCatalog.entry(id: "qwen3-14b")?.label)
        XCTAssertTrue(on32.upgrade?.reason.contains("13 GB download") == false)
    }
}
