import XCTest
@testable import QuenderinKit

/// Cross-platform router-classification conformance: the SAME prompt must classify to the SAME
/// TaskKind on iOS (here) and Android (the "parity:router-*" checks in CoreVerify.kt).
/// Each assertion carries a `parity:router-<id>` marker matching shared/router-parity-vectors.json;
/// scripts/check_router_parity.py (CI) enforces the bijection.
final class RouterParityTests: XCTestCase {

    private func task(_ prompt: String) -> String { "task:\(ModelRouter.classify(prompt).rawValue)" }

    func testClassificationParity() {
        // parity:router-coding-fence
        XCTAssertEqual(task("```python\nprint(1)\n```"), "task:coding")
        // parity:router-coding-keyword
        XCTAssertEqual(task("Why does my SQL query throw an exception?"), "task:coding")
        // parity:router-coding-beats-multilingual - priority pin: coding > multilingual
        XCTAssertEqual(task("用Python写一个函数"), "task:coding")
        // parity:router-reasoning-step-by-step
        XCTAssertEqual(task("Solve this puzzle step by step"), "task:reasoning")
        // parity:router-reasoning-riddle
        XCTAssertEqual(task("Here is a riddle for you"), "task:reasoning")
        // parity:router-multilingual-cjk
        XCTAssertEqual(task("给我讲一个关于森林的故事"), "task:multilingual")
        // parity:router-multilingual-cyrillic
        XCTAssertEqual(task("Расскажи сказку про лес"), "task:multilingual")
        // parity:router-multilingual-translate
        XCTAssertEqual(task("Translate this sentence into English please"), "task:multilingual")
        // parity:router-accented-latin-general - accents stay Latin (threshold counts > 0x24F only)
        XCTAssertEqual(task("Où est la bibliothèque? Merci beaucoup"), "task:general")
        // parity:router-general
        XCTAssertEqual(task("What should I cook tonight?"), "task:general")
    }

    // MARK: route() behavior (platform-local, not part of the classification vectors)

    private func entry(_ id: String, params: Double, ram: Double) -> ModelEntry {
        ModelEntry(id: id, label: id, filename: "\(id).gguf", ramGB: ram, sizeLabel: "x",
                   paramsBillions: params, quantization: "Q4_K_M", urlString: "https://x/y.gguf", sha256: nil)
    }

    func testRoutePrefersTaskFamilyAndLargestFitting() {
        let installed = [
            entry("llama32-1b", params: 1, ram: 0.7),
            entry("qwen25-coder-7b", params: 7, ram: 6.5),
            entry("qwen3-4b", params: 4, ram: 3.6),
        ]
        // Plenty of RAM: coding prompt → the coder model.
        let coding = ModelRouter.route(prompt: "debug this python function", installed: installed,
                                       totalRAMGB: 16, freeRAMGB: 12)
        XCTAssertEqual(coding?.modelID, "qwen25-coder-7b")
        XCTAssertEqual(coding?.task, .coding)
        XCTAssertFalse(coding?.reason.isEmpty ?? true)

        // Tight RAM: the 7B can't load — falls through the preference order to what fits.
        let tight = ModelRouter.route(prompt: "debug this python function", installed: installed,
                                      totalRAMGB: 4, freeRAMGB: 2.5)
        XCTAssertEqual(tight?.modelID, "llama32-1b")
    }

    func testRouteEmptyAndNoPreferredFamily() {
        XCTAssertNil(ModelRouter.route(prompt: "hi", installed: [], totalRAMGB: 16, freeRAMGB: 8))
        // Only an unknown-family model installed → still returns it (largest fallback).
        let odd = [entry("smollm-360m", params: 0.4, ram: 0.5)]
        XCTAssertEqual(ModelRouter.route(prompt: "hi", installed: odd, totalRAMGB: 16, freeRAMGB: 8)?.modelID,
                       "smollm-360m")
    }
}
