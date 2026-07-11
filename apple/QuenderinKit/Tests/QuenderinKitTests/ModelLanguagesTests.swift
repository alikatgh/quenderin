import XCTest
@testable import QuenderinKit

/// Language honesty for a Russian-first user base: every curated model states which human
/// languages it speaks, "no Russian" is said out loud (the Llama-3.2 tier answers in English
/// even when addressed in Russian — live user report, 2026-07-11), and the chat prompt
/// tells the model to mirror the user's language.
final class ModelLanguagesTests: XCTestCase {

    func testEveryCatalogEntryStatesItsLanguages() {
        for m in ModelCatalog.models {
            XCTAssertNotNil(m.languagesLabel, "\(m.id) must state its language support")
            XCTAssertFalse(m.languagesLabel!.isEmpty, "\(m.id) has an empty languages label")
        }
    }

    func testRussianCapabilityIsExplicitPerFamily() {
        // The families we vouch for in Russian lead with it…
        for id in ["qwen36-35b-a3b", "qwen3-14b", "qwen3-4b", "gemma4-12b", "gemma3-4b"] {
            XCTAssertTrue(ModelCatalog.entry(id: id)!.languagesLabel!.hasPrefix("Russian"),
                          "\(id) is a Russian-capable pick — say so first")
        }
        // …and the Llama 3.2 tier says "no Russian" instead of omitting it.
        for id in ["llama32-3b", "llama32-1b", "llama32-1b-q2"] {
            XCTAssertTrue(ModelCatalog.entry(id: id)!.languagesLabel!.contains("no Russian"),
                          "\(id) must state the Russian gap explicitly")
        }
    }

    func testSideloadedEntriesDecodeWithoutTheField() throws {
        // Entries persisted by older builds (SideloadedModels JSON) have no `languages` key —
        // the field is optional so they must keep decoding after the update.
        let old = """
        {"id":"hf:x","label":"X","filename":"x.gguf","ramGb":1.0,"sizeLabel":"1 GB download",
         "paramsBillions":1.0,"quantization":"Q4_K_M","url":"https://example.com/x.gguf","sha256":null}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(ModelEntry.self, from: old)
        XCTAssertNil(entry.languagesLabel)
    }

    func testChatPromptMirrorsTheUsersLanguage() {
        XCTAssertTrue(ConversationContext.defaultSystemPrompt
            .contains("Always reply in the same language the user writes in"),
            "without this line, small models answer Russian questions in English")
    }
}
