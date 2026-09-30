package ai.quenderin.core

import ai.quenderin.app.ModelReleaseJSON
import java.io.File

/** Targeted JVM harness: actual Android JSON decoder + portable validation/offline repository. */
fun main(args: Array<String>) {
    val data = File(args.single()).readBytes()
    val feed = ModelReleaseJSON.decode(data)
    check(feed.models.isNotEmpty() && feed.models.map { it.id }.distinct().size == feed.models.size)
    check(feed.models.all { it.sourceUrl.startsWith("https://huggingface.co/") && it.downloadGB <= 24 })
    val first = feed.models.first()
    check(!first.copy(id = "evil.test/@user?redirect=1").isValid())
    check(!first.copy(filename = "../weights.gguf").isValid())
    check(!first.copy(sha256 = "not-a-checksum").isValid())
    check(!first.copy(downloadBytes = 90_000_000_000).isValid())
    val filtered = feed.copy(models = listOf(first, first, first.copy(id = "../bad"))).validated()
    check(filtered.partial && filtered.models.size == 1)
    check(runCatching { feed.copy(version = 2).validated() }.isFailure)
    check(runCatching { feed.copy(checkedAt = "yesterday").validated() }.isFailure)
    check(runCatching { feed.copy(models = emptyList()).validated() }.isFailure)
    check(runCatching { ModelReleaseJSON.decode(ByteArray(ModelReleaseFeed.MAX_BYTES + 1)) }.isFailure)
    check(ModelReleaseJSON.decode(ModelReleaseJSON.encode(feed)) == feed)
    val known = ModelCatalog.models.first()
    check(first.copy(sha256 = known.sha256!!.uppercase()).catalogEntry() == known)
    check(first.catalogEntry() == null)

    var disk: ModelReleaseFeed? = feed
    var saves = 0
    var failWrite = false
    val cache = object : ModelReleaseCache {
        override fun load() = disk
        override fun save(feed: ModelReleaseFeed) {
            if (failWrite) error("Disk full")
            disk = feed
            saves++
        }
    }
    val offline = ModelReleaseRepository(cache, feed) { error("Network unavailable") }
    val after = offline.refresh(now = 1)
    check(after.feed == feed && after.saved && after.refreshFailed && disk == feed && saves == 0)

    var calls = 0
    val live = feed.copy(checkedAt = "2026-09-30T13:00:00Z")
    val repository = ModelReleaseRepository(cache, feed) { calls++; live }
    check(!repository.refresh(now = 1).saved)
    repository.refresh(now = 30_001)
    check(calls == 1 && saves == 1 && disk == live)
    repository.refresh(force = true, now = 31_000)
    check(calls == 2)
    check(ModelReleaseRepository(cache, feed) { error("Offline") }.snapshot.feed == live)
    val rollback = ModelReleaseRepository(cache, feed) { feed }
    check(rollback.refresh(now = 1).refreshFailed && disk == live)
    failWrite = true
    val newer = live.copy(checkedAt = "2026-09-30T14:00:00Z")
    check(ModelReleaseRepository(cache, feed) { newer }.refresh(now = 1).feed == newer && disk == live)
    println("Android model releases: validation, checksum, cache, outage and rollback checks passed")
}
