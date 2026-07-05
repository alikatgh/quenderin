package ai.quenderin.core

import java.io.File

/**
 * The workspace capabilities — Milestone 2, the first "operate the computer" slice. Twin of
 * iOS `WorkspaceCapabilities.swift`; the workspace seam is a `() -> File?` populated ONLY by
 * an explicit user folder-pick (one folder at a time, on purpose — a small local model
 * reasoning about one bounded directory is predictable).
 */

/** T1: list the workspace folder. Read-only; input is ignored (no path arguments a model
 *  could get creative with). */
class FileListCapability(private val workspace: () -> File?) : Capability {
    override val name = "fs.list"
    override val purpose = "List the files in the workspace folder the user granted. Takes no input."
    override val tier = CapabilityTier.READ_ONLY
    override val blastRadius: BlastRadius = BlastRadius.Read("the workspace folder")

    override fun plan(input: String): ActionPreview {
        val folder = workspace()
            ?: return ActionPreview("Nothing to list: no workspace folder granted yet.", mutates = false)
        return ActionPreview("Would list the contents of \"${folder.name}\". Read-only.", mutates = false)
    }

    override fun run(input: String): String {
        val folder = workspace()
            ?: return "No workspace folder granted. Ask the user to grant one first."
        val names = folder.list()?.filter { !it.startsWith(".") }?.sorted()
            ?: return "Couldn't list \"${folder.name}\" — it may have been moved or deleted."
        if (names.isEmpty()) return "The workspace \"${folder.name}\" is empty."
        val lines = names.take(200).map { if (File(folder, it).isDirectory) "$it/" else it }
        val truncated = if (names.size > 200) "\n[…${names.size - 200} more]" else ""
        return lines.joinToString("\n") + truncated
    }
}

/** A reversal recipe for every workspace write. One entry per executed move, newest last;
 *  [undoLast] plays the inverse. Twin of iOS `UndoJournal`. */
class UndoJournal {
    data class Entry(val from: File, val to: File)

    private val lock = Any()
    private val entries = mutableListOf<Entry>()

    fun record(from: File, to: File) = synchronized(lock) { entries.add(Entry(from, to)); Unit }

    val count: Int get() = synchronized(lock) { entries.size }

    fun undoLast(): String {
        val last = synchronized(lock) { entries.removeLastOrNull() } ?: return "Nothing to undo."
        return if (runCatching { require(last.to.renameTo(last.from)) }.isSuccess) {
            "Moved \"${last.to.name}\" back to where it was."
        } else {
            "Couldn't undo the last move."
        }
    }
}

/**
 * T2 — the FIRST write capability: move a file inside the workspace. Safety is structural:
 * plain-name input only (no paths, no ".."), never overwrites, every move recorded for undo,
 * and the runner demands per-RUN approval because [blastRadius] mutates. Twin of iOS.
 */
class FileMoveCapability(
    private val workspace: () -> File?,
    private val journal: UndoJournal,
) : Capability {
    override val name = "fs.move"
    override val purpose = "Move a file into a subfolder of the workspace. Input: \"<file name> to <subfolder name>\"."
    override val tier = CapabilityTier.REVERSIBLE_WRITE
    override val blastRadius: BlastRadius = BlastRadius.Write("the workspace folder")

    private sealed interface Resolution {
        data class Ok(val file: File, val destDir: File, val fileName: String, val destName: String) : Resolution
        data class Fail(val reason: String) : Resolution
    }

    private fun resolve(input: String): Resolution {
        val folder = workspace()
            ?: return Resolution.Fail("No workspace folder granted. Ask the user to grant one first.")
        val parts = input.split(" to ")
        if (parts.size != 2) {
            return Resolution.Fail("Input must be \"<file name> to <subfolder name>\", e.g. \"report.pdf to Archive\".")
        }
        val fileName = parts[0].trim()
        val destName = parts[1].trim()
        for (name in listOf(fileName, destName)) {
            if (name.isEmpty() || name.contains("/") || name.contains("..")) {
                return Resolution.Fail("File and folder are plain names inside the workspace — paths aren't allowed.")
            }
        }
        val file = File(folder, fileName)
        if (!file.exists()) {
            return Resolution.Fail("No file named \"$fileName\" in the workspace. Use fs.list to see what's there.")
        }
        return Resolution.Ok(file, File(folder, destName), fileName, destName)
    }

    override fun plan(input: String): ActionPreview = when (val r = resolve(input)) {
        is Resolution.Fail -> ActionPreview(r.reason, mutates = false)
        is Resolution.Ok -> ActionPreview(
            "Move \"${r.fileName}\" into \"${r.destName}/\" (inside the workspace; undoable).",
            mutates = true,
        )
    }

    override fun run(input: String): String = when (val r = resolve(input)) {
        is Resolution.Fail -> r.reason
        is Resolution.Ok -> {
            when {
                r.destDir.exists() && !r.destDir.isDirectory -> "\"${r.destName}\" is a file, not a folder."
                !r.destDir.exists() && !r.destDir.mkdir() -> "Couldn't create \"${r.destName}/\"."
                else -> {
                    val target = File(r.destDir, r.fileName)
                    if (target.exists()) {
                        // Never overwrite — reversible means no data is ever lost, incl. at the target.
                        "\"${r.destName}/${r.fileName}\" already exists — refusing to overwrite."
                    } else if (!r.file.renameTo(target)) {
                        "Couldn't move \"${r.fileName}\"."
                    } else {
                        journal.record(from = r.file, to = target)
                        "Moved \"${r.fileName}\" into \"${r.destName}/\". (Undo is available.)"
                    }
                }
            }
        }
    }
}
