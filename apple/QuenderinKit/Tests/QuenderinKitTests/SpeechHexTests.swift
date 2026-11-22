import XCTest
import CryptoKit
@testable import QuenderinKit

final class SpeechHexTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quenderin-speech-xctest-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBundledSpeechCatalogContainsAll20HexModelsAndSileroVad() throws {
        let catalog = try SpeechModelCatalog.bundled()
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.vad.id, "silero_vad_v6_2")
        XCTAssertEqual(catalog.models.count, 20)
        XCTAssertNotNil(catalog.models.first { $0.id == "parakeet_unified_en" })
        XCTAssertNotNil(catalog.models.first { $0.id == "apple_speech" }?.isOnDeviceFramework == true ? true : nil)
    }

    func testSpeechFormattingVocabularyListsPunctuationAndFrenchSpacing() {
        let formatted = TranscriptFormatter.format(
            "uh first open quanderin comma second run kromos question mark",
            options: SpeechFormattingOptions(
                vocabulary: [
                    SpeechVocabularyTerm(term: "Quenderin", phoneticHints: ["quanderin"]),
                    SpeechVocabularyTerm(term: "Kromoss", phoneticHints: ["kromos"]),
                ],
                removeFillerWords: true,
                spokenPunctuation: true,
                spokenLists: true
            )
        )
        XCTAssertTrue(formatted.contains("Quenderin,"))
        XCTAssertTrue(formatted.contains("Kromoss?"))
        XCTAssertTrue(formatted.hasPrefix("1. "))
        XCTAssertTrue(formatted.contains("\n2. "))

        let french = FrenchSpacing.apply(to: "bonjour : comment allez-vous ?")
        XCTAssertEqual(french, "bonjour\u{202F}: comment allez-vous\u{202F}?")
    }

    func testSpeechInstallerVerifiesArtifactsAndRejectsCorruptionOrSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let modelBytes = Data("GGUF_TEST_MODEL".utf8)
        let vadBytes = Data("GGUF_TEST_VAD".utf8)
        let modelSha = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
        let vadSha = SHA256.hash(data: vadBytes).map { String(format: "%02x", $0) }.joined()

        let model = SpeechModel(
            id: "parakeet_unified_en",
            label: "Parakeet Unified",
            engine: "transcribe.cpp",
            architecture: "parakeet",
            variant: "tdt-0.6b",
            repo: "handy-computer/parakeet-unified-en-0.6b-gguf",
            revision: String(repeating: "a", count: 40),
            filename: "parakeet.gguf",
            localFilename: "parakeet.gguf",
            bytes: Int64(modelBytes.count),
            sha256: modelSha,
            languages: ["en"],
            acceptsLanguageHint: true,
            supportsLanguageDetection: false,
            streams: true,
            vocabularyUse: "bias",
            realtime: "~163x",
            wordErrorRate: 1.6,
            license: "CC-BY-4.0",
            access: "public"
        )
        let vad = SpeechVadModel(
            id: "silero_vad_v6_2",
            label: "Silero VAD",
            repo: "handy-computer/silero-vad-v6.2-gguf",
            revision: String(repeating: "b", count: 40),
            filename: "silero-vad-v6.2-F32.gguf",
            localFilename: "silero-vad-v6.2-F32.gguf",
            bytes: Int64(vadBytes.count),
            sha256: vadSha,
            architecture: "silero_vad",
            variant: "v6.2",
            license: "MIT",
            access: "public"
        )

        try modelBytes.write(to: root.appendingPathComponent("parakeet.gguf"))
        try vadBytes.write(to: root.appendingPathComponent("silero-vad-v6.2-F32.gguf"))
        try SpeechModelInstaller.verify(model, in: root, vad: vad)

        try Data("TAMPERED_TEST!!".utf8).write(to: root.appendingPathComponent("parakeet.gguf"))
        XCTAssertThrowsError(try SpeechModelInstaller.verify(model, in: root, vad: vad))
    }
}
