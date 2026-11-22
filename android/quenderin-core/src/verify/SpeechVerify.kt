package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Synthetic bytes only. Verifies Android speech model manifests, checksums, formatting, and unavailable JNI handling. */
fun main() {
    val modelBytes = "GGUF_SPEECH_FIXTURE".toByteArray(Charsets.UTF_8)
    val vadBytes = "GGUF_SILERO_VAD_FIXTURE".toByteArray(Charsets.UTF_8)
    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    val model = SpeechModel(
        id = "parakeet_unified_en",
        label = "Parakeet Unified English",
        engine = "transcribe.cpp",
        architecture = "parakeet",
        variant = "tdt-0.6b-v2-unified-en",
        repo = "handy-computer/parakeet-unified-en-0.6b-gguf",
        revision = "a".repeat(40),
        filename = "parakeet-unified-en-0.6b-Q8_0.gguf",
        localFilename = "parakeet-unified-en-0.6b-Q8_0.gguf",
        bytes = modelBytes.size.toLong(),
        sha256 = sha256(modelBytes),
        languages = listOf("en"),
        acceptsLanguageHint = true,
        supportsLanguageDetection = false,
        streams = true,
        vocabularyUse = "bias",
        realtime = "~163x",
        wordErrorRate = 1.60,
        license = "CC-BY-4.0",
        access = "public",
    )
    val whisperBin = model.copy(
        id = "nb_whisper_medium",
        filename = "ggml-model-q5_0.bin",
        localFilename = "ggml-model-q5_0.bin",
    )
    val vad = SpeechVadModel(
        id = "silero_vad_v6_2",
        label = "Silero VAD v6.2",
        repo = "handy-computer/silero-vad-v6.2-gguf",
        revision = "b".repeat(40),
        filename = "silero-vad-v6.2-F32.gguf",
        localFilename = "silero-vad-v6.2-F32.gguf",
        bytes = vadBytes.size.toLong(),
        sha256 = sha256(vadBytes),
        architecture = "silero_vad",
        variant = "v6.2",
        license = "MIT",
        access = "public",
    )
    model.validate()
    whisperBin.validate()
    vad.validate()

    val root = Files.createTempDirectory("quenderin-speech-kt-").toFile().canonicalFile
    try {
        fun mustFail(block: () -> Unit) {
            check(runCatching(block).isFailure)
        }
        mustFail { SpeechModelFiles.verify(model, root, vad) }

        File(root, model.localFilename!!).writeBytes(modelBytes)
        File(root, vad.localFilename).writeBytes(vadBytes)
        SpeechModelFiles.verify(model, root, vad)

        File(root, vad.localFilename).writeBytes("CORRUPT".toByteArray())
        mustFail { SpeechModelFiles.verify(model, root, vad) }
        File(root, vad.localFilename).writeBytes(vadBytes)

        check(runCatching {
            SpeechModelFiles.verify(model, root, vad) { true }
        }.exceptionOrNull() is CancellationException)

        val linked = File(root, "linked")
        Files.createSymbolicLink(linked.toPath(), root.toPath())
        mustFail { SpeechModelFiles.verify(model, linked, vad) }
        linked.delete()

        mustFail { model.copy(localFilename = "../bad.gguf").validate() }
        mustFail {
            SpeechModelFiles.verify(
                model.copy(id = "apple_speech", engine = "apple_speech"),
                root,
            )
        }

        val formatted = SpokenTextFormatter.format(
            "uh first open quanderin comma second test kromos question mark",
            SpeechFormattingOptions(
                vocabulary = listOf(
                    SpeechVocabularyTerm("Quenderin", listOf("quanderin")),
                    SpeechVocabularyTerm("Kromoss", listOf("kromos")),
                ),
                removeFillerWords = true,
                spokenPunctuation = true,
                spokenLists = true,
            ),
        )
        check(formatted == "1. open Quenderin,\n2. test Kromoss?") { "Unexpected formatted string: $formatted" }
        check(SpokenTextFormatter.applyFrenchSpacing("salut !") == "salut\u202F!")

        if (!NativeSpeechBridge.available) {
            val engine = NativeSpeechEngine()
            mustFail {
                engine.transcribe(SpeechTranscriptionRequest(model, root, shortArrayOf(0, 100, -100)))
            }
        }
        println("PASS: Android speech catalog, checksum, formatting, symlink, and JNI guard fixtures verified")
    } finally {
        root.listFiles()?.forEach { it.delete() }
        root.delete()
    }
}
