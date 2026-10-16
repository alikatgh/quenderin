package ai.quenderin.app

import android.content.Context
import android.util.AtomicFile
import ai.quenderin.core.ModelReleaseCache
import ai.quenderin.core.ModelReleaseFeed
import ai.quenderin.core.ModelReleaseRepository
import java.io.File
import java.io.InputStream
import java.io.ByteArrayOutputStream
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** Metadata only: fixed URL, no cookies, account, chat, device profile or search query. */
internal fun modelReleaseRepository(context: Context): ModelReleaseRepository {
    return ModelReleasesStore.get(context.applicationContext)
}

private object ModelReleasesStore {
    private var repository: ModelReleaseRepository? = null
    @Synchronized fun get(context: Context): ModelReleaseRepository =
        repository ?: createModelReleaseRepository(context).also { repository = it }
}

private fun createModelReleaseRepository(context: Context): ModelReleaseRepository {
    val cache = AtomicFile(File(context.filesDir, "model-releases.json"))
    return ModelReleaseRepository(
        cache = object : ModelReleaseCache {
            override fun load(): ModelReleaseFeed? =
                runCatching { cache.openRead().use { ModelReleaseJSON.decode(readBounded(it)) } }.getOrNull()

            override fun save(feed: ModelReleaseFeed) {
                val stream = cache.startWrite()
                try {
                    stream.write(ModelReleaseJSON.encode(feed))
                    cache.finishWrite(stream)
                } catch (error: Exception) {
                    cache.failWrite(stream)
                    throw error
                }
            }
        },
        bundled = context.assets.open("model-releases.json").use { ModelReleaseJSON.decode(readBounded(it)) },
        fetch = ::fetchModelReleases,
    )
}

internal fun fetchModelReleases(): ModelReleaseFeed {
    val connection = URL("https://quenderin.org/api/model-releases").openConnection() as HttpsURLConnection
    try {
        connection.connectTimeout = 12_000
        connection.readTimeout = 12_000
        connection.instanceFollowRedirects = false
        connection.useCaches = false
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Cookie", "")
        require(connection.responseCode == 200 && connection.contentLengthLong <= ModelReleaseFeed.MAX_BYTES) { "Release feed unavailable" }
        return connection.inputStream.use { ModelReleaseJSON.decode(readBounded(it)) }
    } finally { connection.disconnect() }
}

internal fun readBounded(input: InputStream): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    val deadline = System.nanoTime() + 20_000_000_000L
    while (true) {
        require(System.nanoTime() < deadline) { "Release feed timed out" }
        val count = input.read(buffer)
        if (count < 0) break
        require(output.size() + count <= ModelReleaseFeed.MAX_BYTES) { "Release feed too large" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
