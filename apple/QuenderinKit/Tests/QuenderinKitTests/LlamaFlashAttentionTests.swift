import XCTest
@testable import QuenderinKit
#if canImport(llama)
import llama
#endif

/// Pins the pinned llama.xcframework's Flash Attention API surface — the thing that blocked
/// enabling FA for months was "the field name varies across llama.cpp versions", so this test
/// makes the CURRENT framework's contract explicit and fails loudly if a future framework bump
/// changes it. Compiled only when the real framework is linked (Route A/C); CI's mock-only
/// build skips it.
final class LlamaFlashAttentionTests: XCTestCase {
    #if canImport(llama)
    func testFlashAttentionEnumContract() {
        // The tri-state enum the engine relies on. If a framework bump removes or renumbers
        // these, LlamaEngine.loadLocked's flash_attn_type assignment needs revisiting.
        XCTAssertEqual(LLAMA_FLASH_ATTN_TYPE_AUTO.rawValue, -1)
        XCTAssertEqual(LLAMA_FLASH_ATTN_TYPE_DISABLED.rawValue, 0)
        XCTAssertEqual(LLAMA_FLASH_ATTN_TYPE_ENABLED.rawValue, 1)
    }

    func testDefaultParamsFlashAttentionState() {
        // Documents what llama_context_default_params() ships as the FA default in THIS
        // framework build. The engine sets flash_attn_type EXPLICITLY (never trusts the
        // default), but knowing the default matters for reasoning about older sessions.
        let params = llama_context_default_params()
        let name = String(cString: llama_flash_attn_type_name(params.flash_attn_type))
        print("[probe] llama_context_default_params().flash_attn_type = \(params.flash_attn_type.rawValue) (\(name))")
        // AUTO (-1) is the modern upstream default; if a future bump changes it, surface that.
        XCTAssertEqual(params.flash_attn_type, LLAMA_FLASH_ATTN_TYPE_AUTO,
                       "default flash_attn_type changed — re-verify LlamaEngine's assumptions")
    }
    #endif
}
