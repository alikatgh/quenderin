package ai.quenderin.core

/** Tiny source fixtures: no weights, network, Android SDK, or native execution. Shared by JUnit and
 * the dependency-free host harness so the same checks run with the existing Kotlin compiler. */
internal object ModelArtifactChecks {
    private val firstBytes = "GGUFmetadata".toByteArray()
    private val secondBytes = "GGUFsecond-shard-data".toByteArray()
    private fun artifact(name: String, bytes: ByteArray) = ModelArtifact(name,
        "https://huggingface.co/fixture/split/resolve/${"1".repeat(40)}/Q2_K/$name?download=true",
        ModelIntegrity.sha256Hex(bytes), bytes.size.toLong())
    private val first = artifact("test-00001-of-00002.gguf", firstBytes)
    private val second = artifact("test-00002-of-00002.gguf", secondBytes)
    private val model = ModelEntry("split-test", "Split fixture", first.filename, 1.0, "32 bytes", 1.0,
        "Q2_K", first.url, first.sha256, downloadBytes = first.downloadBytes + second.downloadBytes,
        artifacts = listOf(first, second))

    private class Sink : FileSink {
        val files = HashMap<String, ByteArray>()
        override fun existingSize(path: String) = files[path]?.size?.toLong() ?: 0L
        override fun truncate(path: String) { files.remove(path) }
        override fun append(path: String, bytes: ByteArray) { files[path] = (files[path] ?: byteArrayOf()) + bytes }
        override fun head(path: String, n: Int) = files[path]?.take(n)?.toByteArray() ?: byteArrayOf()
        override fun sha256(path: String) = ModelIntegrity.sha256Hex(requireNotNull(files[path]))
        override fun finalize(tempPath: String, finalPath: String) { files[finalPath] = requireNotNull(files.remove(tempPath)) }
    }

    private class Http(private val payloads: Map<String, ByteArray>, private val resume: Boolean = true,
                       private val afterChunk: () -> Unit = {}) : HttpRangeClient {
        val calls = ArrayList<Pair<String, Long>>()
        override val supportsBoundedRanges = true
        override fun openRange(url: String, startBytes: Long, endBytes: Long): RangeResponse = error("Split downloads must be sequential")
        override fun open(url: String, offsetBytes: Long): RangeResponse {
            calls += url to offsetBytes
            val bytes = requireNotNull(payloads[url])
            val start = if (resume) offsetBytes.toInt() else 0
            val body = sequence {
                for (piece in bytes.copyOfRange(start.coerceAtMost(bytes.size), bytes.size).toList().chunked(3)) {
                    yield(piece.toByteArray())
                    afterChunk()
                }
            }
            return RangeResponse(bytes.size.toLong(), resume && offsetBytes > 0, body)
        }
    }

    fun verify() {
        metadataBeforeIO()
        completeAndCorrupt()
        resumeCancellationAndProgress()
        aggregateProgressIsBounded()
        retainedVerificationCancelsAndRestoreNeverFetches()
        storageAndDisk()
        museRuntimeAndMemory()
        museOutput()
        println("Android split-model + Muse fixture checks passed")
    }

    private fun metadataBeforeIO() {
        ModelArtifacts.validate(model)
        val invalid = listOf(
            model.copy(artifacts = listOf(first, first)),
            model.copy(artifacts = listOf(first), downloadBytes = first.downloadBytes),
            model.copy(artifacts = listOf(second, first), filename = second.filename, url = second.url, sha256 = second.sha256),
            model.copy(artifacts = listOf(first.copy(filename = "../escape.gguf"), second)),
            model.copy(artifacts = listOf(first.copy(filename = "folder\\escape.gguf"), second)),
            model.copy(artifacts = listOf(first.copy(url = first.url.replace("1".repeat(40), "main")), second)),
            model.copy(artifacts = listOf(first.copy(url = first.url.replace("huggingface.co", "huggingface.co.evil.test")), second)),
            model.copy(artifacts = listOf(first.copy(sha256 = "bad"), second)),
            model.copy(artifacts = listOf(first.copy(downloadBytes = 0), second)),
            model.copy(downloadBytes = 1L), model.copy(filename = second.filename),
            model.copy(artifacts = listOf(first.copy(downloadBytes = Long.MAX_VALUE), second)),
            model.copy(artifacts = List(65) { first.copy(filename = "shard-$it.gguf") }),
        )
        val noIO = object : FileSink {
            override fun existingSize(path: String): Long = error("unexpected disk I/O")
            override fun truncate(path: String): Unit = error("unexpected disk I/O")
            override fun append(path: String, bytes: ByteArray): Unit = error("unexpected disk I/O")
            override fun head(path: String, n: Int): ByteArray = error("unexpected disk I/O")
            override fun sha256(path: String): String = error("unexpected disk I/O")
            override fun finalize(tempPath: String, finalPath: String): Unit = error("unexpected disk I/O")
        }
        val noNetwork = object : HttpRangeClient {
            override fun open(url: String, offsetBytes: Long): RangeResponse = error("unexpected network")
        }
        for (entry in invalid) {
            check(runCatching { ModelDownloadEngine(noNetwork, noIO, DownloadStore(), "/models").download(entry) {} }
                .exceptionOrNull() is IllegalArgumentException)
            check(runCatching { ModelArtifacts.isComplete(entry, "/models/${entry.filename}", noIO) }
                .exceptionOrNull() is IllegalArgumentException)
        }
        check(runCatching {
            ModelDownloadEngine(noNetwork, noIO, DownloadStore(), "/models", isCancelled = { true }).download(model) {}
        }.exceptionOrNull() is DownloadCancelledException) { "Cancellation stops before file/network I/O" }
    }

    private fun completeAndCorrupt() {
        val sink = Sink()
        val path = "/models/${first.filename}"
        sink.files[path] = firstBytes
        check(!ModelArtifacts.isComplete(model, path, sink)) { "Metadata-only shard is not ready" }
        sink.files["/models/${second.filename}"] = secondBytes
        check(ModelArtifacts.isComplete(model, path, sink))
        check(!ModelArtifacts.isComplete(model, "/models/renamed.gguf", sink))
        sink.files["/models/${second.filename}"] = secondBytes.copyOf().also { it[5] = 0 }
        check(!ModelArtifacts.isComplete(model, path, sink)) { "Same-size corruption must fail" }
        val before = requireNotNull(sink.files["/models/${second.filename}"]).copyOf()
        val http = Http(mapOf(first.url to firstBytes, second.url to secondBytes))
        check(runCatching { ModelDownloadEngine(http, sink, DownloadStore(), "/models").download(model) {} }
            .exceptionOrNull() is DownloadException)
        check(http.calls.isEmpty())
        check(requireNotNull(sink.files["/models/${second.filename}"]).contentEquals(before)) { "Existing corrupt user path is preserved" }
    }

    private fun resumeCancellationAndProgress() {
        val sink = Sink()
        sink.files["/models/${first.filename}"] = firstBytes
        sink.files["/models/${second.filename}.part"] = secondBytes.copyOf(6)
        val http = Http(mapOf(first.url to firstBytes, second.url to secondBytes))
        val store = DownloadStore()
        val progress = ArrayList<Double>()
        val engine = ModelDownloadEngine(http, sink, store, "/models")
        check(engine.needsFetch(model))
        val remaining = engine.remainingDownloadBytes(model)
        check(remaining == second.downloadBytes - 6L)
        check(DiskSpace.check(model, remaining, marginBytes = 0L, remainingDownloadBytes = remaining).hasRoom)
        check(!DiskSpace.check(model, remaining, marginBytes = 0L).hasRoom)
        val metadataOnly = object : FileSink by sink {
            override fun sha256(path: String): String = error("UI must not hash weights")
            override fun head(path: String, n: Int): ByteArray = error("UI must not read weight content")
        }
        check(ModelArtifacts.estimatedRemainingDownloadBytes(model, "/models", metadataOnly) == remaining)
        check(engine.download(model) { progress += it } == "/models/${first.filename}")
        check(http.calls == listOf(second.url to 6L)) { "Verified shards reused; partial shard resumes" }
        check(progress.zipWithNext().all { (a, b) -> b >= a } && progress.last() == 1.0)
        check(progress.first() >= (first.downloadBytes + 6.0) / requireNotNull(model.downloadBytes))
        check(store.all().isEmpty() && !engine.needsFetch(model))
        check(engine.remainingDownloadBytes(model) == 0L)
        val calls = http.calls.size
        engine.download(model) {}
        check(http.calls.size == calls)

        // Constraint loss on shard two retains shard one and a real .part; a new process resumes it.
        val stoppedSink = Sink()
        var chunks = 0
        var cancelled = false
        val stoppingHttp = Http(mapOf(first.url to firstBytes, second.url to secondBytes), afterChunk = {
            chunks++
            if (chunks == 5) cancelled = true
        })
        val stoppedStore = DownloadStore()
        val stopped = ModelDownloadEngine(stoppingHttp, stoppedSink, stoppedStore, "/models", isCancelled = { cancelled })
        check(runCatching { stopped.download(model) {} }.exceptionOrNull() is DownloadCancelledException)
        check(stoppedStore.get(model.id)?.state == PersistedDownload.State.PAUSED)
        check(stoppedSink.existingSize("/models/${first.filename}") == first.downloadBytes)
        check(stoppedSink.existingSize("/models/${second.filename}") == 0L)
        val offset = stoppedSink.existingSize("/models/${second.filename}.part")
        check(offset > 0L && offset < second.downloadBytes)
        val resumedHttp = Http(mapOf(first.url to firstBytes, second.url to secondBytes))
        ModelDownloadEngine(resumedHttp, stoppedSink, DownloadStore(stoppedStore.snapshot()), "/models").download(model) {}
        check(resumedHttp.calls == listOf(second.url to offset))

        // A server that ignores Range restarts just that shard, retaining the other one.
        val ignoredSink = Sink().also {
            it.files["/models/${first.filename}"] = firstBytes
            it.files["/models/${second.filename}.part"] = secondBytes.copyOf(6)
        }
        ModelDownloadEngine(Http(mapOf(second.url to secondBytes), resume = false), ignoredSink, DownloadStore(), "/models")
            .download(model) {}
        check(ModelArtifacts.isComplete(model, "/models/${first.filename}", ignoredSink))

        // Ordinary single-file catalog/import users retain optional hash/size behavior.
        val single = model.copy(id = "single", artifacts = emptyList(), downloadBytes = null, sha256 = null,
            url = "https://example.test/model.gguf")
        val singleHttp = object : HttpRangeClient {
            override fun open(url: String, offsetBytes: Long) = RangeResponse(firstBytes.size.toLong(), false, sequenceOf(firstBytes))
        }
        val singleEngine = ModelDownloadEngine(singleHttp, Sink(), DownloadStore(), "/models")
        check(singleEngine.download(single) {} == "/models/${first.filename}")
        check(!singleEngine.needsFetch(single))
    }

    private fun storageAndDisk() {
        val storage = InMemoryModelStorage(mapOf(first.filename to first.downloadBytes))
        val manager = ModelManager(storage, catalog = listOf(model))
        check(!manager.isInstalled(model.id) && manager.installed().isEmpty())
        check(manager.totalBytesUsed == first.downloadBytes)
        storage.install(second.filename, second.downloadBytes)
        check(manager.isInstalled(model.id))
        check(manager.installed().single().sizeBytes == model.downloadBytes)
        check(manager.setActive(model.id) && manager.reclaimableBytes == 0L)
        check(manager.delete(model.id) == model.downloadBytes && manager.activeModelId == null)
        check(storage.installedFilenames().isEmpty())
        storage.install(first.filename, first.downloadBytes)
        storage.install("${second.filename}.part", 6L)
        check(manager.delete(model.id) == first.downloadBytes + 6L) { "Deleting an incomplete set removes every owned shard/part" }
        check(DiskSpace.estimatedDownloadBytes(model) == model.downloadBytes)
        check(!DiskSpace.check(model, first.downloadBytes, marginBytes = 0L).hasRoom)
        check(DiskSpace.check(model, requireNotNull(model.downloadBytes), marginBytes = 0L).hasRoom)
    }

    private fun aggregateProgressIsBounded() {
        val manyBytes = ModelIntegrity.GGUF_MAGIC + ByteArray(8_188) { (it % 17).toByte() }
        val largeSecond = artifact(second.filename, manyBytes)
        val many = model.copy(artifacts = listOf(first, largeSecond),
            downloadBytes = first.downloadBytes + largeSecond.downloadBytes)
        val sink = Sink()
        val store = DownloadStore()
        var persistedUpdates = 0
        var completedBytes = -1L
        store.onChange = { rows ->
            persistedUpdates++
            rows.firstOrNull()?.takeIf { it.state == PersistedDownload.State.COMPLETED }?.let {
                completedBytes = it.bytesDownloaded
            }
        }
        var outwardUpdates = 0
        ModelDownloadEngine(Http(mapOf(first.url to firstBytes, second.url to manyBytes)), sink, store, "/models",
            progressClockNanos = { 0L }).download(many) { outwardUpdates++ }
        // >2,700 chunks must produce only ~100 fraction reports plus forced boundary snapshots.
        check(outwardUpdates in 2..120 && persistedUpdates in 2..125)
        check(completedBytes == many.downloadBytes && store.all().isEmpty())

        // Slow small chunks still report by elapsed time before a shard/fraction boundary.
        var now = 0L
        val timedStore = DownloadStore()
        var reportedSixBytes = false
        timedStore.onChange = { rows -> if (rows.firstOrNull()?.bytesDownloaded == 6L) reportedSixBytes = true }
        ModelDownloadEngine(Http(mapOf(first.url to firstBytes, second.url to secondBytes),
            afterChunk = { now += 1_000_000_000L }), Sink(), timedStore, "/models", progressStep = 1.0,
            progressClockNanos = { now }).download(model) {}
        check(reportedSixBytes)

        // Cancel below the fraction threshold: the PAUSED record still has the exact retained bytes.
        val pausedSink = Sink()
        val pausedStore = DownloadStore()
        val secondPartial = "/models/${second.filename}.part"
        val engine = ModelDownloadEngine(Http(mapOf(first.url to firstBytes, second.url to manyBytes)),
            pausedSink, pausedStore, "/models", isCancelled = { pausedSink.existingSize(secondPartial) >= 30L },
            progressClockNanos = { 0L })
        check(runCatching { engine.download(many) {} }.exceptionOrNull() is DownloadCancelledException)
        val record = requireNotNull(pausedStore.get(many.id))
        check(record.state == PersistedDownload.State.PAUSED && record.bytesDownloaded == first.downloadBytes + 30L)
    }

    private fun museRuntimeAndMemory() {
        unavailableWorkflows()
        val pinned = requireNotNull(ModelCatalog.entry("muse-spark-open-q2-k"))
        ModelArtifacts.validate(pinned)
        check(pinned.artifacts.size == 22 && ModelRuntimeSupport.isVerifiedMuseManifest(pinned))
        check(pinned.downloadBytes == pinned.artifacts.sumOf { it.downloadBytes })
        check(!ModelRuntimeSupport.isVerifiedMuseManifest(pinned.copy(id = "custom")))
        check(!ModelRuntimeSupport.isVerifiedMuseManifest(pinned.copy(artifacts = listOf(pinned.artifacts.first()),
            downloadBytes = pinned.artifacts.first().downloadBytes)))
        val muse = model.copy(id = "muse-spark-import", label = "Muse Spark", ramGB = 0.01, paramsBillions = 0.01)
        check(ModelRuntimeSupport.isMuse(muse) && !ModelRuntimeSupport.supportsMuse)
        check(!ModelRuntimeSupport.supports(muse))
        val phone = MemoryFitness.check(muse, 16.0, 16.0, museRuntimeAvailable = true)
        check(!phone.canLoad && phone.requiredGB == 429.0)
        check(!MemoryFitness.check(muse, 1024.0, 1024.0, museRuntimeAvailable = false).canLoad)
        check(MemoryFitness.check(muse, 1024.0, 1024.0, museRuntimeAvailable = true).canLoad)
        check(ModelRouter.route("hello", listOf(muse), 1024.0, 1024.0) == null)
        val renamed = muse.copy(id = "custom", label = "Custom", filename = "renamed.gguf", url = "https://example.test/a.gguf",
            artifacts = listOf(first.copy(filename = "Muse-Spark-00001-of-00022.gguf")))
        check(ModelRuntimeSupport.isMuse(renamed))
        check(LlamaEngine(1024.0).runCatching { load(muse, "/unused") }.exceptionOrNull()?.message == ModelRuntimeSupport.MUSE_UNAVAILABLE_MESSAGE)
        check(ModelRuntimeSupport.MUSE_MAX_CONTEXT_TOKENS == 4096)
    }

    private fun unavailableWorkflows() {
        val encoded = model.copy(id = "custom", label = "Custom", filename = "custom.gguf", artifacts = emptyList(),
            url = "https://example.invalid/NVIDIA%2DNemotron%2D3.5%2DBolt%2D74B%2DA9B.gguf")
        check(ModelRuntimeSupport.requiresWeeklyTextRuntime(encoded))
        check(ModelRuntimeSupport.unsupportedWorkflowReason(encoded) == null)
        val names = listOf("Beam-1.0-501B-A23B", "Hy-Memory-30B-A3B", "Nemotron-3.5-Super-VL-120B",
            "Step-5-Preview", "Granite-Switch-4.1", "Nemotron-3.5-Bolt-E4B", "Nemotron-3.5-Unknown", "Bolt-E4B", "Super-VL-120B", "Beam1.0-501B")
        for (name in names) for (field in 0..3) {
            val candidate = model.copy(id = if (field == 0) name else "custom", label = if (field == 1) name else "Custom",
                filename = if (field == 2) "$name.gguf" else "custom.gguf", url = if (field == 3) "https://example.invalid/$name.gguf" else "https://example.invalid/custom.gguf",
                artifacts = emptyList())
            check(!ModelRuntimeSupport.supports(candidate))
            check(ModelRuntimeSupport.unsupportedWorkflowReason(candidate) != null)
            check(!MemoryFitness.check(candidate, 1024.0, 1024.0, prismRuntimeAvailable = true,
                museRuntimeAvailable = true, weeklyTextRuntimeAvailable = true).canLoad)
            val http = Http(emptyMap())
            check(runCatching { ModelDownloadEngine(http, Sink(), DownloadStore(), "/models").download(candidate) {} }.isFailure)
            check(http.calls.isEmpty())
        }
        for (name in listOf("Granite-4.0", "Hunyuan-3.0", "Nemotron-3-Super", "Step-3.5-Flash")) {
            check(ModelRuntimeSupport.unsupportedWorkflowReason(listOf(name)) == null)
        }
        for (candidate in ModelCatalog.models.filter { it.id.startsWith("jais3") || it.id.startsWith("nemotron35") || it.id.startsWith("minicpm-v47") || it.id == "lfm25-24b-a2b" }) {
            check(ModelRuntimeSupport.unsupportedWorkflowReason(candidate) == null)
        }
        fun integer(value: Long, width: Int) = ByteArray(width) { (value shr (it * 8)).toByte() }
        fun string(value: String): ByteArray = value.toByteArray().let { integer(it.size.toLong(), 8) + it }
        for ((architecture, name) in listOf("beam" to "Custom", "step5_vl" to "Custom", "hy_v3" to "Hy-Memory-30B-A3B", "nemotron_h_moe" to "Nemotron-3.5-Super-VL-120B")) {
            val bytes = "GGUF".toByteArray() + integer(3, 4) + integer(0, 8) + integer(2, 8) +
                string("general.architecture") + integer(8, 4) + string(architecture) +
                string("general.name") + integer(8, 4) + string(name)
            val file = java.io.File.createTempFile("unavailable-model-", ".gguf")
            try {
                file.writeBytes(bytes)
                check(ModelRuntimeSupport.metadataUnavailableReason(file.path) != null)
                file.writeBytes(bytes.copyOf(bytes.size - 1))
                check(runCatching { ModelRuntimeSupport.metadataUnavailableReason(file.path) }.isFailure)
            } finally { file.delete() }
        }
    }

    private fun retainedVerificationCancelsAndRestoreNeverFetches() {
        val sink = Sink().also {
            it.files["/models/${first.filename}"] = firstBytes
            it.files["/models/${second.filename}"] = secondBytes
        }
        var cancelled = false
        var hashCalls = 0
        val cancellable = object : FileSink by sink {
            override fun sha256(path: String, isCancelled: () -> Boolean): String {
                hashCalls++
                repeat(8) { step ->
                    if (step == 3) cancelled = true
                    if (isCancelled()) throw DownloadCancelledException("fixture hash cancelled")
                }
                return sink.sha256(path)
            }
        }
        val store = DownloadStore()
        val states = ArrayList<PersistedDownload.State>()
        store.onChange = { rows -> rows.firstOrNull()?.let { states += it.state } }
        val http = Http(mapOf(first.url to firstBytes, second.url to secondBytes))
        val result = runCatching {
            ModelDownloadEngine(http, cancellable, store, "/models", isCancelled = { cancelled }).download(model) {}
        }
        check(result.exceptionOrNull() is DownloadCancelledException && hashCalls == 1)
        check(PersistedDownload.State.VERIFYING in states && store.get(model.id)?.state == PersistedDownload.State.PAUSED)
        check(http.calls.isEmpty() && requireNotNull(sink.files["/models/${first.filename}"]).contentEquals(firstBytes))
        cancelled = false
        check(runCatching { ModelArtifacts.isComplete(model, "/models/${first.filename}", cancellable) { cancelled } }
            .exceptionOrNull() is DownloadCancelledException)
        cancelled = false
        check(runCatching { ModelArtifacts.remainingDownloadBytes(model, "/models", cancellable) { cancelled } }
            .exceptionOrNull() is DownloadCancelledException)

        // A restore job has no network constraint, so drift MUST fail without opening HTTP.
        check(ModelArtifacts.hasCompleteFileSet(model, "/models", sink))
        ModelDownloadEngine(http, sink, DownloadStore(), "/models", allowNetwork = false).download(model) {}
        sink.files.remove("/models/${second.filename}")
        check(runCatching {
            ModelDownloadEngine(http, sink, DownloadStore(), "/models", allowNetwork = false).download(model) {}
        }.exceptionOrNull() is DownloadException)
        check(http.calls.isEmpty())

        // Exercise the production streaming hasher on a tiny generated source fixture, not weights.
        val file = java.io.File.createTempFile("quenderin-hash-fixture-", ".tmp")
        try {
            val content = ModelIntegrity.GGUF_MAGIC + ByteArray(192 * 1024) { (it % 31).toByte() }
            file.writeBytes(content)
            var polls = 0
            check(runCatching { ModelIntegrity.sha256Hex(file) { ++polls >= 3 } }
                .exceptionOrNull() is DownloadCancelledException)
            check(polls == 3 && file.length() == content.size.toLong())
            val jvm = JvmFileSink()
            val original = jvm.sha256(file.path)
            check(original == ModelIntegrity.sha256Hex(content))
            val oldTime = java.nio.file.Files.getLastModifiedTime(file.toPath())
            java.io.RandomAccessFile(file, "rw").use { it.seek(12); it.write(127) }
            java.nio.file.Files.setLastModifiedTime(file.toPath(), oldTime)
            check(jvm.sha256(file.path) != original) { "Same-size edit with restored mtime invalidates the receipt" }
        } finally { check(file.delete()) }
    }

    private fun museOutput() {
        val wire = " to=self<|message|>secret chain<|eom|><|start|>assistant to=commentary<|message|>aside" +
            "<|eom|><|start|>assistant to=user<|message|>Final answer.<|eot|>trailing hidden"
        for (width in 1..37) {
            val streamed = StringBuilder()
            val filter = MuseOutputFilter { streamed.append(it) }
            wire.chunked(width).forEach(filter::accept)
            filter.finish()
            check(streamed.toString() == "Final answer.") { "Split channel framing width=$width" }
        }
        check(MuseOutputFilter.finalText(wire) == "Final answer.")
        check(MuseOutputFilter.finalText("<|message|>Direct.<|eot|>") == "Direct.")
        check(MuseOutputFilter.finalText(" to=browser<|message|>tool output<|eot|>").isEmpty())
        check(MuseOutputFilter.finalText(" to=self<|message|>private partial").isEmpty())
        check(MuseOutputFilter.finalText(" to=user<|message|>Answer<|eo") == "Answer")
        check(MuseOutputFilter.finalText("x".repeat(513) + "<|message|>secret").isEmpty())
        check(MuseOutputFilter.finalText(" to=user<|message|><|unknown|>secret").isEmpty())
    }
}
