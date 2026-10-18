package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID

/** App-private approved facts, deliberately separate from goal→tool skill records. */
class HyApprovedMemoryStore(private val directory: File) {
    @Synchronized fun save(proposal: HyMemoryProposal) {
        require(runCatching { UUID.fromString(proposal.id).toString() == proposal.id }.getOrDefault(false)
            && proposal.text.isNotBlank() && proposal.text.length <= 512) { "Invalid selected memory." }
        check(directory.mkdirs() || directory.isDirectory) { "Could not create the private memory store." }
        require(directory.canonicalFile == directory.absoluteFile) { "The memory store must not contain symbolic links." }
        val destination = File(directory, "${proposal.id}.json")
        val encoded = "{\"id\":${HyMemory.quote(proposal.id)},\"text\":${HyMemory.quote(proposal.text)},\"saved\":true}"
        if (destination.exists()) {
            require(Files.isRegularFile(destination.toPath(), LinkOption.NOFOLLOW_LINKS) && destination.length() <= 4096 && destination.readText() == encoded) { "A different memory already uses this ID; it has been preserved." }; return
        }
        require((directory.list()?.size ?: error("Could not inspect the memory store.")) < 1000) { "The approved memory bank is full. Existing memories are preserved." }
        val staging = File(directory, ".${UUID.randomUUID()}.partial")
        try {
            Files.write(staging.toPath(), encoded.toByteArray(Charsets.UTF_8), java.nio.file.StandardOpenOption.CREATE_NEW)
            Files.move(staging.toPath(), destination.toPath())
        } finally { if (staging.exists()) staging.delete() }
    }
}
