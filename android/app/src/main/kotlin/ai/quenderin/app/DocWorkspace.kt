package ai.quenderin.app

import ai.quenderin.core.ActionPreview
import ai.quenderin.core.BlastRadius
import ai.quenderin.core.Capability
import ai.quenderin.core.CapabilityTier
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile

/**
 * The workspace fs.* capabilities on ANDROID — DocumentFile twins of the core's File-based
 * `WorkspaceCapabilities`. Scoped storage (API 29+) forbids raw File writes to shared folders,
 * so the phone's "organize this folder" runs over the Storage Access Framework instead: the
 * user grants ONE tree via the system folder picker, and every operation goes through that
 * grant. Same names, same tiers, same input contracts and message wording as the core twins —
 * the model and the parity docs see ONE fs.* surface; only the storage plumbing differs.
 *
 * Everything goes through the [DocTree] seam so the capability logic is structured for a fake
 * (the seam-and-fake discipline); the one production-only surface is [SafDocTree], the thin
 * DocumentFile/DocumentsContract adapter.
 */

/** One granted folder tree — the minimal surface the capabilities need. */
interface DocTree {
    /** The folder's display name, or null when the grant is gone. */
    fun name(): String?
    /** Top-level entries: name → isDirectory. */
    fun list(): List<Pair<String, Boolean>>?
    /** True when a top-level entry with this name exists. */
    fun exists(name: String): Boolean
    /** Create (or return) a top-level subfolder. Null on failure. */
    fun ensureDir(name: String): DocTree?
    /** Move a top-level FILE of this tree into [dest] (a subtree of the same grant). */
    fun moveInto(name: String, dest: DocTree): Boolean
    /** Rename a top-level file. */
    fun rename(from: String, to: String): Boolean
}

/** The production adapter: DocumentFile + DocumentsContract over one persisted tree grant. */
class SafDocTree(private val context: Context, private val dir: DocumentFile) : DocTree {
    override fun name(): String? = if (dir.exists()) dir.name else null

    override fun list(): List<Pair<String, Boolean>>? {
        if (!dir.exists()) return null
        return dir.listFiles().mapNotNull { f -> f.name?.let { it to f.isDirectory } }
    }

    override fun exists(name: String): Boolean = dir.findFile(name) != null

    override fun ensureDir(name: String): DocTree? {
        val existing = dir.findFile(name)
        val target = when {
            existing != null && existing.isDirectory -> existing
            existing != null -> return null   // a FILE with that name is in the way
            else -> dir.createDirectory(name)
        }
        return target?.let { SafDocTree(context, it) }
    }

    override fun moveInto(name: String, dest: DocTree): Boolean {
        val destDir = (dest as? SafDocTree)?.dir ?: return false
        val file = dir.findFile(name) ?: return false
        if (file.isDirectory) return false
        // moveDocument is the atomic path; a provider that doesn't support it gets copy+delete.
        return runCatching {
            DocumentsContract.moveDocument(context.contentResolver, file.uri, dir.uri, destDir.uri) != null
        }.getOrElse { copyThenDelete(file, destDir, name) }
    }

    override fun rename(from: String, to: String): Boolean {
        val file = dir.findFile(from) ?: return false
        return runCatching { file.renameTo(to) }.getOrDefault(false)
    }

    private fun copyThenDelete(file: DocumentFile, destDir: DocumentFile, name: String): Boolean = runCatching {
        val mime = file.type ?: "application/octet-stream"
        val created = destDir.createFile(mime, name) ?: return false
        context.contentResolver.openInputStream(file.uri).use { input ->
            context.contentResolver.openOutputStream(created.uri).use { out ->
                requireNotNull(input); requireNotNull(out)
                input.copyTo(out)
            }
        }
        file.delete()
    }.getOrDefault(false)

    companion object {
        /** Rebuild the tree from a persisted grant URI; null when the grant no longer resolves. */
        fun fromGrant(context: Context, uri: Uri): SafDocTree? {
            val doc = DocumentFile.fromTreeUri(context, uri) ?: return null
            if (!doc.exists() || !doc.isDirectory) return null
            return SafDocTree(context, doc)
        }
    }
}

/** One plain name: non-empty, no separators, no traversal — the core twins' exact gate. */
private fun plainName(n: String): Boolean = n.isNotEmpty() && !n.contains("/") && !n.contains("..")

/** A reversal recipe per executed move (newest last); [undoLast] plays the inverse.
 *  The DocumentFile twin of the core `UndoJournal`. */
class DocUndoJournal {
    private data class Entry(val name: String, val from: DocTree, val to: DocTree)

    private val lock = Any()
    private val entries = mutableListOf<Entry>()

    fun record(name: String, from: DocTree, to: DocTree) =
        synchronized(lock) { entries.add(Entry(name, from, to)); Unit }

    val count: Int get() = synchronized(lock) { entries.size }

    fun undoLast(): String {
        val last = synchronized(lock) { entries.removeLastOrNull() } ?: return "Nothing to undo."
        return if (last.to.moveInto(last.name, last.from)) {
            "Moved \"${last.name}\" back to where it was."
        } else {
            "Couldn't undo the last move."
        }
    }
}

/** T1: list the workspace folder. Same contract as the core `FileListCapability`. */
class DocFileListCapability(private val workspace: () -> DocTree?) : Capability {
    override val name = "fs.list"
    override val purpose = "List the files in the workspace folder the user granted. Takes no input."
    override val tier = CapabilityTier.READ_ONLY
    override val blastRadius: BlastRadius = BlastRadius.Read("the workspace folder")

    override fun plan(input: String): ActionPreview {
        val folder = workspace()?.name()
            ?: return ActionPreview("Nothing to list: no workspace folder granted yet.", mutates = false)
        return ActionPreview("Would list the contents of \"$folder\". Read-only.", mutates = false)
    }

    override fun run(input: String): String {
        val tree = workspace() ?: return "No workspace folder granted. Ask the user to grant one first."
        val folder = tree.name() ?: return "The workspace folder is gone — ask the user to grant it again."
        val entries = tree.list() ?: return "Couldn't list \"$folder\" — it may have been moved or deleted."
        val names = entries.filter { !it.first.startsWith(".") }.sortedBy { it.first }
        if (names.isEmpty()) return "The workspace \"$folder\" is empty."
        val lines = names.take(200).map { (n, isDir) -> if (isDir) "$n/" else n }
        val truncated = if (names.size > 200) "\n[…${names.size - 200} more]" else ""
        return lines.joinToString("\n") + truncated
    }
}

/** T2: move a file into a subfolder. Same "<file> to <subfolder>" contract as the core twin:
 *  plain names only, never overwrites, creates the destination folder, journal-recorded. */
class DocFileMoveCapability(
    private val workspace: () -> DocTree?,
    private val journal: DocUndoJournal,
) : Capability {
    override val name = "fs.move"
    override val purpose = "Move a file into a subfolder of the workspace. Input: \"<file> to <subfolder>\"."
    override val tier = CapabilityTier.REVERSIBLE_WRITE
    override val blastRadius: BlastRadius = BlastRadius.Write("the workspace folder")

    private fun parse(input: String): Pair<String, String>? {
        val parts = input.split(" to ")
        if (parts.size != 2) return null
        val file = parts[0].trim()
        val sub = parts[1].trim().removeSuffix("/")
        if (!plainName(file) || !plainName(sub)) return null
        return file to sub
    }

    override fun plan(input: String): ActionPreview {
        if (workspace() == null) return ActionPreview("No workspace folder granted. Ask the user to grant one first.", mutates = false)
        val p = parse(input)
            ?: return ActionPreview("Input must be \"<file> to <subfolder>\" — plain names, no paths.", mutates = false)
        return ActionPreview("Move \"${p.first}\" into \"${p.second}/\" (inside the workspace; undoable).", mutates = true)
    }

    override fun run(input: String): String {
        val tree = workspace() ?: return "No workspace folder granted. Ask the user to grant one first."
        val p = parse(input) ?: return "Input must be \"<file> to <subfolder>\" — plain names, no paths."
        val (fileName, subName) = p
        if (!tree.exists(fileName)) return "No file named \"$fileName\" in the workspace. Use fs.list to see what's there."
        val dest = tree.ensureDir(subName)
            ?: return "Couldn't use \"$subName/\" as a folder (a file with that name may be in the way)."
        if (dest.exists(fileName)) return "\"$subName/$fileName\" already exists — refusing to overwrite."
        if (!tree.moveInto(fileName, dest)) return "Couldn't move \"$fileName\"."
        journal.record(fileName, from = tree, to = dest)
        return "Moved \"$fileName\" into \"$subName/\". (Undo is available.)"
    }
}

/** T2: rename a file. Same "<current name> to <new name>" contract as the core twin. */
class DocFileRenameCapability(
    private val workspace: () -> DocTree?,
) : Capability {
    override val name = "fs.rename"
    override val purpose = "Rename a file in the workspace. Input: \"<current name> to <new name>\"."
    override val tier = CapabilityTier.REVERSIBLE_WRITE
    override val blastRadius: BlastRadius = BlastRadius.Write("the workspace folder")

    private fun parse(input: String): Pair<String, String>? {
        val parts = input.split(" to ")
        if (parts.size != 2) return null
        val from = parts[0].trim()
        val to = parts[1].trim()
        if (!plainName(from) || !plainName(to)) return null
        return from to to
    }

    override fun plan(input: String): ActionPreview {
        if (workspace() == null) return ActionPreview("No workspace folder granted. Ask the user to grant one first.", mutates = false)
        val p = parse(input)
            ?: return ActionPreview("Input must be \"<current name> to <new name>\", both plain names of workspace files.", mutates = false)
        return ActionPreview("Rename \"${p.first}\" to \"${p.second}\" (inside the workspace).", mutates = true)
    }

    override fun run(input: String): String {
        val tree = workspace() ?: return "No workspace folder granted. Ask the user to grant one first."
        val p = parse(input) ?: return "Input must be \"<current name> to <new name>\" — plain names, no paths."
        val (from, to) = p
        if (!tree.exists(from)) return "No file named \"$from\" in the workspace. Use fs.list to see what's there."
        if (tree.exists(to)) return "\"$to\" already exists — refusing to overwrite."
        if (!tree.rename(from, to)) return "Couldn't rename \"$from\"."
        return "Renamed \"$from\" to \"$to\"."
    }
}

/** T2: move a file into the workspace's visible Trash/ subfolder — never a real delete.
 *  Same contract as the core twin; Undo moves it back. */
class DocFileTrashCapability(
    private val workspace: () -> DocTree?,
    private val journal: DocUndoJournal,
) : Capability {
    override val name = "fs.trash"
    override val purpose = "Move a file into the workspace's Trash folder. Input: \"<file name>\"."
    override val tier = CapabilityTier.REVERSIBLE_WRITE
    override val blastRadius: BlastRadius = BlastRadius.Write("the workspace folder")

    override fun plan(input: String): ActionPreview {
        val name = input.trim()
        if (workspace() == null || !plainName(name)) {
            return ActionPreview("Input is one plain file name from the workspace.", mutates = false)
        }
        return ActionPreview("Move \"$name\" into the workspace's Trash/ folder (undoable — not deleted).", mutates = true)
    }

    override fun run(input: String): String {
        val tree = workspace() ?: return "No workspace folder granted. Ask the user to grant one first."
        val name = input.trim()
        if (!plainName(name)) return "Input is one plain file name — no paths."
        if (name == "Trash") return "Refusing to trash the Trash folder itself."
        if (!tree.exists(name)) return "No file named \"$name\" in the workspace. Use fs.list to see what's there."
        val trash = tree.ensureDir("Trash")
            ?: return "Couldn't create the Trash/ folder."
        if (trash.exists(name)) return "Trash/ already holds a \"$name\" — refusing to overwrite it."
        if (!tree.moveInto(name, trash)) return "Couldn't move \"$name\" to Trash/."
        journal.record(name, from = tree, to = trash)
        return "Moved \"$name\" into Trash/ (not deleted — Undo moves it back)."
    }
}

/** The Android workspace set, ready to register once the user grants a tree. */
fun docWorkspaceCapabilities(workspace: () -> DocTree?, journal: DocUndoJournal): List<Capability> = listOf(
    DocFileListCapability(workspace),
    DocFileMoveCapability(workspace, journal),
    DocFileRenameCapability(workspace),
    DocFileTrashCapability(workspace, journal),
)
