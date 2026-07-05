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

/** T2: rename a file inside the workspace — same spine as fs.move (plain names, no overwrite,
 *  journal-recorded so Undo restores the old name). Twin of iOS `FileRenameCapability`. */
class FileRenameCapability(
    private val workspace: () -> File?,
    private val journal: UndoJournal,
) : Capability {
    override val name = "fs.rename"
    override val purpose = "Rename a file in the workspace. Input: \"<current name> to <new name>\"."
    override val tier = CapabilityTier.REVERSIBLE_WRITE
    override val blastRadius: BlastRadius = BlastRadius.Write("the workspace folder")

    private fun resolve(input: String): Triple<File, File, Pair<String, String>>? {
        val folder = workspace() ?: return null
        val parts = input.split(" to ")
        if (parts.size != 2) return null
        val fromName = parts[0].trim()
        val toName = parts[1].trim()
        for (n in listOf(fromName, toName)) {
            if (n.isEmpty() || n.contains("/") || n.contains("..")) return null
        }
        return Triple(File(folder, fromName), File(folder, toName), fromName to toName)
    }

    override fun plan(input: String): ActionPreview {
        if (workspace() == null) return ActionPreview("No workspace folder granted. Ask the user to grant one first.", mutates = false)
        val r = resolve(input)
        if (r == null || !r.first.exists()) {
            return ActionPreview("Input must be \"<current name> to <new name>\", both plain names of workspace files.", mutates = false)
        }
        return ActionPreview("Rename \"${r.third.first}\" to \"${r.third.second}\" (inside the workspace; undoable).", mutates = true)
    }

    override fun run(input: String): String {
        if (workspace() == null) return "No workspace folder granted. Ask the user to grant one first."
        val r = resolve(input) ?: return "Input must be \"<current name> to <new name>\" — plain names, no paths."
        val (from, to, names) = r
        if (!from.exists()) return "No file named \"${names.first}\" in the workspace. Use fs.list to see what's there."
        if (to.exists()) return "\"${names.second}\" already exists — refusing to overwrite."
        if (!from.renameTo(to)) return "Couldn't rename \"${names.first}\"."
        journal.record(from = from, to = to)
        return "Renamed \"${names.first}\" to \"${names.second}\". (Undo is available.)"
    }
}

/** T2: move a file into the workspace's visible "Trash" subfolder — deliberately NOT the system
 *  trash: identical semantics on every platform, in plain sight, Undo moves it back. Twin of iOS. */
class FileTrashCapability(
    private val workspace: () -> File?,
    private val journal: UndoJournal,
) : Capability {
    override val name = "fs.trash"
    override val purpose = "Move a file into the workspace's Trash folder. Input: \"<file name>\"."
    override val tier = CapabilityTier.REVERSIBLE_WRITE
    override val blastRadius: BlastRadius = BlastRadius.Write("the workspace folder")

    override fun plan(input: String): ActionPreview {
        val name = input.trim()
        if (workspace() == null || name.isEmpty() || name.contains("/") || name.contains("..")) {
            return ActionPreview("Input is one plain file name from the workspace.", mutates = false)
        }
        return ActionPreview("Move \"$name\" into the workspace's Trash/ folder (undoable — not deleted).", mutates = true)
    }

    override fun run(input: String): String {
        val folder = workspace() ?: return "No workspace folder granted. Ask the user to grant one first."
        val name = input.trim()
        if (name.isEmpty() || name.contains("/") || name.contains("..")) return "Input is one plain file name — no paths."
        val file = File(folder, name)
        if (!file.exists()) return "No file named \"$name\" in the workspace. Use fs.list to see what's there."
        val trashDir = File(folder, "Trash")
        if (trashDir.exists() && !trashDir.isDirectory) return "\"Trash\" is a file, not a folder."
        if (!trashDir.exists() && !trashDir.mkdir()) return "Couldn't create Trash/."
        val target = File(trashDir, name)
        if (target.exists()) return "Trash/$name already exists — refusing to overwrite."
        if (!file.renameTo(target)) return "Couldn't trash \"$name\"."
        journal.record(from = file, to = target)
        return "Moved \"$name\" to Trash/. (Undo restores it; nothing is deleted.)"
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
