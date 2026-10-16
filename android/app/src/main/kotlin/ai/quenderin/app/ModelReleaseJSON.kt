package ai.quenderin.app

import ai.quenderin.core.ModelRelease
import ai.quenderin.core.ModelReleaseFeed
import org.json.JSONArray
import org.json.JSONObject

/** Uses Android's built-in JSON reader; also tested on the JVM with the same org.json API. */
object ModelReleaseJSON {
    fun decode(bytes: ByteArray): ModelReleaseFeed {
        require(bytes.size <= ModelReleaseFeed.MAX_BYTES) { "Release feed too large" }
        val obj = JSONObject(bytes.toString(Charsets.UTF_8))
        val rows = obj.getJSONArray("models")
        require(rows.length() in 1..60) { "Invalid release count" }
        val models = (0 until rows.length()).map { index ->
            val m = rows.getJSONObject(index)
            ModelRelease(m.getString("id"), m.getString("name"), m.getString("createdAt"),
                m.getString("quantization"), m.getLong("downloadBytes"), m.getString("sha256"),
                m.getString("revision"), m.getString("filename"), m.getString("license"))
        }
        return ModelReleaseFeed(obj.getInt("version"), obj.getString("checkedAt"),
            obj.getBoolean("partial"), models, obj.optString("freshness").takeIf { it.isNotEmpty() }).validated()
    }

    fun encode(feed: ModelReleaseFeed): ByteArray {
        val obj = JSONObject().put("version", feed.version).put("checkedAt", feed.checkedAt).put("partial", feed.partial)
        feed.freshness?.let { obj.put("freshness", it) }
        val models = JSONArray()
        feed.models.forEach { m ->
            models.put(JSONObject().put("id", m.id).put("name", m.name).put("createdAt", m.createdAt)
                .put("quantization", m.quantization).put("downloadBytes", m.downloadBytes)
                .put("sha256", m.sha256).put("revision", m.revision).put("filename", m.filename).put("license", m.license))
        }
        return obj.put("models", models).toString().toByteArray(Charsets.UTF_8)
    }
}
