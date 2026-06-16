package ai.quenderin.core

/**
 * A model that is downloaded and present on disk: its catalog entry, on-disk size, and whether
 * it's the active (loaded) one.
 */
data class InstalledModel(val model: ModelEntry, val sizeBytes: Long, val isActive: Boolean) {
    val id: String get() = model.id
}

/**
 * The filesystem behind [ModelManager] — which model files exist, their sizes, and how to
 * delete one. Abstracted so the manager is pure and testable; the app supplies a `File`-backed
 * implementation over the models directory, tests use [InMemoryModelStorage].
 */
interface ModelStorage {
    fun installedFilenames(): List<String>
    fun sizeBytes(filename: String): Long
    fun delete(filename: String)
}

/** In-memory model storage for tests and previews. */
class InMemoryModelStorage(initial: Map<String, Long> = emptyMap()) : ModelStorage {
    private val files = HashMap<String, Long>(initial)
    fun install(filename: String, sizeBytes: Long) { files[filename] = sizeBytes }
    override fun installedFilenames(): List<String> = files.keys.toList()
    override fun sizeBytes(filename: String): Long = files[filename] ?: 0L
    override fun delete(filename: String) { files.remove(filename) }
}

/**
 * Manages the set of on-device models: which are installed, which is active, how much disk they
 * use, switching the active one, and deleting one to reclaim space — a real constraint on a
 * phone with several multi-GB models. Pure logic over a [ModelStorage] seam + the catalog, so
 * it unit-tests with no real files. Twin of Swift `ModelManager`. (Loading the active model
 * into the engine stays in the app; this owns *what's on disk*, not inference.)
 */
class ModelManager(
    private val storage: ModelStorage,
    initialActiveModelId: String? = null,
) {
    var activeModelId: String? = initialActiveModelId
        private set

    /** Installed catalog models — active first, then largest first, then by id for stability. */
    fun installed(): List<InstalledModel> {
        val present = storage.installedFilenames().toSet()
        return ModelCatalog.models
            .filter { present.contains(it.filename) }
            .map { InstalledModel(it, storage.sizeBytes(it.filename), it.id == activeModelId) }
            .sortedWith(
                compareByDescending<InstalledModel> { it.isActive }
                    .thenByDescending { it.sizeBytes }
                    .thenBy { it.id },
            )
    }

    fun isInstalled(id: String): Boolean {
        val entry = ModelCatalog.entry(id) ?: return false
        return storage.installedFilenames().contains(entry.filename)
    }

    /** Total bytes used by all installed models. */
    val totalBytesUsed: Long get() = installed().sumOf { it.sizeBytes }

    /** Bytes freeable without touching the active model. */
    val reclaimableBytes: Long get() = installed().filter { !it.isActive }.sumOf { it.sizeBytes }

    /** Make an installed model the active one. No-op returning false if it isn't installed. */
    fun setActive(id: String): Boolean {
        if (!isInstalled(id)) return false
        activeModelId = id
        return true
    }

    /**
     * Delete a model's file to reclaim space; returns bytes reclaimed. Deleting the active model
     * clears [activeModelId] (the app must load another). 0 if it isn't installed.
     */
    fun delete(id: String): Long {
        val entry = ModelCatalog.entry(id) ?: return 0L
        if (!isInstalled(id)) return 0L
        val freed = storage.sizeBytes(entry.filename)
        storage.delete(entry.filename)
        if (activeModelId == id) activeModelId = null
        return freed
    }
}
