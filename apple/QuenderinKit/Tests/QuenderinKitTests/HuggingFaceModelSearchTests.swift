import XCTest
@testable import QuenderinKit

/// The open-catalog search: parse the Hugging Face API shape, resolve quants to sizes, and map to a
/// hardware-checkable ModelEntry — all without a live call (canned JSON).
final class HuggingFaceModelSearchTests: XCTestCase {

    func testParseSearchExtractsIdDownloadsAndGating() throws {
        let json = """
        [
          {"id":"bartowski/Meta-Llama-3.1-8B-Instruct-GGUF","downloads":271546,"gated":false,"likes":12,"tags":["gguf","text-generation"],"pipeline_tag":"text-generation"},
          {"id":"meta-llama/Llama-3.1-8B-Instruct","downloads":9000000,"gated":"manual"}
        ]
        """.data(using: .utf8)!
        let hits = try HuggingFaceCatalog.parseSearch(json)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].id, "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")
        XCTAssertEqual(hits[0].downloads, 271546)
        XCTAssertFalse(hits[0].gated, "a community re-quant is ungated → downloadable without a token")
        XCTAssertTrue(hits[1].gated, "an official gated repo needs HF license acceptance")
        XCTAssertEqual(hits[0].likes, 12)
        XCTAssertEqual(hits[0].pipelineTag, "text-generation")
        XCTAssertTrue(hits[0].detailBlurb.contains("community GGUF"))
        XCTAssertEqual(hits[0].hubURL?.absoluteString, "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")
    }

    func testSearchFiltersExcludeGatedAndCapParams() {
        let hits = [
            HFModelHit(id: "a/Llama-3-8B-GGUF", downloads: 100, gated: false),
            HFModelHit(id: "b/Llama-70B-GGUF", downloads: 50, gated: false),
            HFModelHit(id: "c/Meta-8B", downloads: 200, gated: true),
        ]
        let open = ModelSearchFilters(excludeGated: true).apply(to: hits, totalRAMGB: 16)
        XCTAssertEqual(open.map(\.id), ["a/Llama-3-8B-GGUF", "b/Llama-70B-GGUF"])
        let small = ModelSearchFilters(maxParamsB: 8).apply(to: hits, totalRAMGB: 16)
        XCTAssertFalse(small.contains(where: { $0.id.contains("70B") }))
    }

    func testParseQuantsKeepsOnlyGgufWithSizeAndSha() throws {
        let json = """
        {"siblings":[
          {"rfilename":"README.md","size":1200},
          {"rfilename":"Model-Q4_K_M.gguf","size":10,"lfs":{"oid":"abc123","size":4700000000}},
          {"rfilename":"Model-IQ3_XS.gguf","lfs":{"oid":"def456","size":3500000000}}
        ]}
        """.data(using: .utf8)!
        let q = try HuggingFaceCatalog.parseQuants(repo: "acme/Model-GGUF", json)
        XCTAssertEqual(q.count, 2, "the README is dropped; only .gguf files remain")
        XCTAssertEqual(q[0].filename, "Model-Q4_K_M.gguf")
        XCTAssertEqual(q[0].sizeBytes, 4700000000, "LFS size wins over the tiny pointer 'size'")
        XCTAssertEqual(q[0].sha256, "abc123", "the LFS oid is the verifiable sha256")
        XCTAssertEqual(q[0].quant, "Q4_K_M")
        XCTAssertEqual(q[1].quant, "IQ3_XS")
        XCTAssertEqual(q[0].downloadURL?.absoluteString,
                       "https://huggingface.co/acme/Model-GGUF/resolve/main/Model-Q4_K_M.gguf?download=true")
    }

    /// Review fix: a filename with a URL-invalid character (a space) must still yield a valid,
    /// percent-encoded download URL — else it's nil on macOS 13/iOS 16 and the quant is undownloadable.
    func testDownloadURLPercentEncodesTheFilename() {
        let q = HFQuant(repo: "acme/Model-GGUF", filename: "model (v2)-Q4_K_M.gguf", sizeBytes: 1, sha256: nil)
        let url = q.downloadURL
        XCTAssertNotNil(url, "a filename with a space must still produce a valid URL")
        XCTAssertTrue(url!.absoluteString.contains("%20"), "the space must be percent-encoded")
        XCTAssertTrue(url!.absoluteString.hasSuffix("?download=true"))
    }

    func testQuantLabelFallsBackWhenNoTagPresent() {
        XCTAssertEqual(HuggingFaceCatalog.quantLabel("foo.Q8_0.gguf"), "Q8_0")
        XCTAssertEqual(HuggingFaceCatalog.quantLabel("foo-iq4_nl.gguf"), "IQ4_NL")
        XCTAssertEqual(HuggingFaceCatalog.quantLabel("plain-model.gguf"), "GGUF")
    }

    func testEstimatedParamsPicksTheSizeNotTheVersion() {
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("Meta-Llama-3.1-8B-Instruct"), 8, accuracy: 0.001)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("Llama-3.2-1B-Instruct"), 1, accuracy: 0.001)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("Qwen2.5-Coder-7B"), 7, accuracy: 0.001)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("some-mystery-model"), 7, accuracy: 0.001, "sane fallback")
    }

    /// HF GGUF re-uploads often omit "7B"/"22B" — codenames must not all collapse to the 7B fallback
    /// (that made max-size filters look dead: every Mistral row was ~7B).
    func testEstimatedParamsKnowsFamilyCodenames() {
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("MaziyarPanahi/Mistral-Large-Instruct-2411-GGUF"), 123, accuracy: 0.1)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("MaziyarPanahi/Mistral-Small-Instruct-2409-GGUF"), 22, accuracy: 0.1)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("MaziyarPanahi/Mistral-Nemo-Instruct-2407-GGUF"), 12, accuracy: 0.1)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("TheBloke/Mistral-7B-Instruct-v0.2-GGUF"), 7, accuracy: 0.1)
        XCTAssertEqual(HuggingFaceCatalog.estimatedParams("someone/Phi-3-mini-4k-instruct-GGUF"), 3.8, accuracy: 0.1)
    }

    func testMaxParamsFilterUsesCodenameEstimates() {
        let hits = [
            HFModelHit(id: "a/Mistral-Large-Instruct-2411-GGUF", downloads: 100, gated: false),
            HFModelHit(id: "b/Mistral-7B-Instruct-v0.3-GGUF", downloads: 200, gated: false),
            HFModelHit(id: "c/Mistral-Nemo-Instruct-2407-GGUF", downloads: 150, gated: false),
        ]
        let le14 = ModelSearchFilters(maxParamsB: 14).apply(to: hits, totalRAMGB: 32)
        XCTAssertEqual(Set(le14.map(\.id)), Set(["b/Mistral-7B-Instruct-v0.3-GGUF", "c/Mistral-Nemo-Instruct-2407-GGUF"]),
                       "Large (~123B) must drop under ≤14B; 7B and Nemo (~12B) stay")
        let le8 = ModelSearchFilters(maxParamsB: 8).apply(to: hits, totalRAMGB: 32)
        XCTAssertEqual(le8.map(\.id), ["b/Mistral-7B-Instruct-v0.3-GGUF"])
    }

    func testSortByParamsDescOrdersCodenames() {
        let hits = [
            HFModelHit(id: "a/Mistral-7B-GGUF", downloads: 1, gated: false),
            HFModelHit(id: "b/Mistral-Large-GGUF", downloads: 1, gated: false),
            HFModelHit(id: "c/Mistral-Nemo-GGUF", downloads: 1, gated: false),
        ]
        let sorted = ModelSearchFilters(sort: .paramsDesc).apply(to: hits, totalRAMGB: 64)
        XCTAssertEqual(sorted.map(\.id), [
            "b/Mistral-Large-GGUF",
            "c/Mistral-Nemo-GGUF",
            "a/Mistral-7B-GGUF",
        ])
    }

    /// A resolved quant becomes a ModelEntry the existing fitness check understands.
    func testCandidateMapsToAHardwareCheckableEntry() {
        let quant = HFQuant(repo: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
                            filename: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
                            sizeBytes: 4_700_000_000, sha256: "deadbeef")
        let entry = HuggingFaceCatalog.candidate(from: quant, label: "Llama 3.1 8B (Q4_K_M)")
        XCTAssertEqual(entry.paramsBillions, 8, accuracy: 0.001)
        XCTAssertEqual(entry.quantization, "Q4_K_M")
        XCTAssertEqual(entry.sha256, "deadbeef", "HF's sha keeps the download verifiable")
        XCTAssertTrue(entry.downloadURL != nil)
        // Fits a 16 GB Mac, blocked on a 4 GB one — the same gate the curated catalog uses.
        XCTAssertTrue(MemoryFitness.check(model: entry, totalGB: 16, freeGB: 16).canLoad)
        XCTAssertFalse(MemoryFitness.check(model: entry, totalGB: 4, freeGB: 4).canLoad)
    }
}
