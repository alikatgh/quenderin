package ai.quenderin.core

import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.URI
import java.net.CookieHandler
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

data class VisionInstalledModel(val modelFile: File, val projectorFile: File)

/** Dedicated exact model+projector sets; this never selects a normal answer model. */
class VisionModelInstaller(val directory: File) {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var connection: HttpsURLConnection? = null
    fun prepare() { cancelled.set(false) }
    fun cancel() { cancelled.set(true); connection?.disconnect() }
    private fun checkCancelled() { if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException("Vision operation cancelled.") }
    private fun canonical(model: VisionModelDescriptor): VisionModelDescriptor = VisionModels.model(model.id) ?: error("Choose a pinned vision preset.")
    private fun target(model: VisionModelDescriptor): File = File(directory, model.id).also {
        require(it.canonicalFile == it.absoluteFile) { "The vision model folder must not contain symbolic links." }
    }
    fun hasComponents(model: VisionModelDescriptor): Boolean = runCatching { val pinned = canonical(model); val folder = target(pinned)
        pinned.artifacts.all { val file = File(folder, it.filename); Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) && file.length() == it.bytes }
    }.getOrDefault(false)
    private fun identity(file: File): Map<String, Any> {
        require(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) { "A vision component must be a regular file, not a symlink." }
        return Files.readAttributes(file.toPath(), "unix:dev,ino,size,lastModifiedTime,ctime", LinkOption.NOFOLLOW_LINKS)
    }
    private fun verify(part: VisionArtifact, file: File) {
        checkCancelled(); val before = identity(file)
        require(before["size"] == part.bytes) { "Missing or incomplete ${part.filename}. Existing files are preserved." }
        val digest = MessageDigest.getInstance("SHA-256"); var count = 0L
        file.inputStream().use { input ->
            val magic = ByteArray(4); require(input.read(magic) == 4 && magic.contentEquals(byteArrayOf(71, 71, 85, 70))) { "The vision component is not a GGUF." }
            digest.update(magic); count = 4
            val buffer = ByteArray(65_536)
            while (true) {
                checkCancelled(); val size = input.read(buffer); if (size < 0) break
                require(size <= part.bytes - count) { "A vision component changed during verification." }; digest.update(buffer, 0, size); count += size
            }
        }
        val hash = digest.digest().joinToString("") { "%02x".format(it) }
        require(count == part.bytes && hash == part.sha256 && identity(file) == before) { "Vision component checksum or identity mismatch. Existing files are preserved." }
    }
    fun verify(model: VisionModelDescriptor, memory: Long, disk: Long): VisionInstalledModel {
        val pinned = canonical(model); checkResources(pinned, memory, disk)
        val folder = target(pinned); pinned.artifacts.forEach { verify(it, File(folder, it.filename)) }
        return VisionInstalledModel(File(folder, pinned.artifacts.first { it.role == "model" }.filename), File(folder, pinned.artifacts.first { it.role == "projector" }.filename))
    }
    @Synchronized fun install(model: VisionModelDescriptor, memory: Long, disk: Long, progress: (Float) -> Unit): VisionInstalledModel {
        val pinned = canonical(model); checkResources(pinned, memory, disk); checkCancelled()
        val folder = target(pinned)
        var remaining = 0L
        pinned.artifacts.forEach { part -> val file = File(folder, part.filename)
            if (Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) verify(part, file) else remaining += part.bytes
        }
        checkResources(pinned, memory, disk, remaining)
        check(folder.mkdirs() || folder.isDirectory) { "Could not create the private vision folder." }; target(pinned)
        val total = pinned.artifacts.sumOf { it.bytes }; var completed = 0L
        for (part in pinned.artifacts) {
            checkCancelled(); val final = File(folder, part.filename)
            if (!Files.exists(final.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                val staging = File(folder, ".${UUID.randomUUID()}.partial")
                try {
                    download(part, staging) { progress((completed.toDouble() + part.bytes * it) .div(total).toFloat()) }
                    verify(part, staging); checkCancelled(); Files.move(staging.toPath(), final.toPath()) // No replacement.
                } finally { if (staging.exists()) staging.delete() }
            }
            completed += part.bytes; progress(completed.toFloat() / total)
        }
        return verify(pinned, memory, disk)
    }
    private fun download(part: VisionArtifact, file: File, progress: (Double) -> Unit) {
        require(CookieHandler.getDefault() == null) { "Public vision downloads require a connection without automatic cookies." }
        var url = URI(part.url); var opened: HttpsURLConnection? = null
        try {
            for (attempt in 0..8) {
                checkCancelled(); require(url.scheme == "https" && url.userInfo == null && url.fragment == null) { "Unsafe vision artifact URL." }
                val next = url.toURL().openConnection() as HttpsURLConnection; opened = next; connection = next
                if (cancelled.get()) throw CancellationException("Vision installation cancelled.")
                next.instanceFollowRedirects = false; next.connectTimeout = 30_000; next.readTimeout = 60_000; next.useCaches = false
                val status = next.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    val location = next.getHeaderField("Location") ?: error("Invalid vision download redirect.")
                    require(location.length <= 8192) { "Vision download redirect exceeds its limit." }; url = url.resolve(location); next.disconnect(); opened = null; continue
                }
                require(status == 200 && (next.contentLengthLong < 0 || next.contentLengthLong == part.bytes)) { "The server did not return the complete pinned component." }
                var count = 0L; var reported = 0.0
                next.inputStream.use { input -> Files.newOutputStream(file.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
                    val buffer = ByteArray(65_536)
                    while (true) {
                        checkCancelled(); val size = input.read(buffer); if (size < 0) break
                        require(size <= part.bytes - count) { "Vision download exceeded the pinned size." }; output.write(buffer, 0, size); count += size
                        val fraction = count.toDouble() / part.bytes; if (fraction - reported >= .002) { reported = fraction; progress(fraction) }
                    }
                } }
                require(count == part.bytes) { "The vision component download was incomplete." }; return
            }
            error("Too many vision download redirects.")
        } finally { opened?.disconnect(); connection = null }
    }
    companion object {
        fun checkResources(model: VisionModelDescriptor, memory: Long, disk: Long, remaining: Long = 0) {
            require(memory >= model.minimumMemoryBytes) { "This complete vision model needs at least ${model.minimumMemoryBytes / 1_073_741_824} GiB of available app memory, including projector and context." }
            require(remaining >= 0 && remaining <= Long.MAX_VALUE - 67_108_864 && disk >= remaining + 67_108_864) { "Insufficient disk for every remaining component and a 64 MiB reserve." }
        }
    }
}

/** A bounded private copy of precisely the image selected by the native picker. */
object VisionSelectedImage {
    const val MAX_BYTES = 8_388_608
    fun copy(input: InputStream, directory: File, cancelled: () -> Boolean = { false }): File {
        check(directory.mkdirs() || directory.isDirectory) { "Could not create the selected-image folder." }
        require(directory.canonicalFile == directory.absoluteFile) { "The selected-image folder must not contain symlinks." }
        val target = File(directory, "${UUID.randomUUID()}.image"); var complete = false
        try {
            var count = 0
            Files.newOutputStream(target.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
                val buffer = ByteArray(65_536)
                while (true) {
                    if (cancelled() || Thread.currentThread().isInterrupted) throw CancellationException("Image selection cancelled.")
                    val size = input.read(buffer); if (size < 0) break
                    require(size <= MAX_BYTES - count) { "Choose one PNG or JPEG no larger than 8 MiB." }; output.write(buffer, 0, size); count += size
                }
            }
            require(count > 0) { "The selected image is empty." }; validate(target); complete = true; return target
        } finally { if (!complete) target.delete() }
    }
    fun validate(file: File) {
        require(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) && file.length() in 1..MAX_BYTES.toLong()) { "Choose one PNG or JPEG no larger than 8 MiB." }
        RandomAccessFile(file, "r").use { data ->
            fun dimensions(width: Long, height: Long) { require(width in 1..4096 && height in 1..4096 && width * height <= 16_000_000) { "Still images are limited to 4,096 pixels per side and 16 million pixels." } }
            val head = ByteArray(8); data.readFully(head)
            if (head.contentEquals(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10))) {
                var first = true; var idat = false
                repeat(4096) {
                    require(data.filePointer + 12 <= data.length()) { "Incomplete PNG." }
                    val count = data.readInt().toLong() and 0xffffffffL; val type = data.readInt()
                    require(count <= data.length() - data.filePointer - 4) { "Incomplete PNG chunk." }
                    if (first) { require(type == 0x49484452 && count == 13L) { "Invalid PNG header." }; dimensions(data.readInt().toLong() and 0xffffffffL, data.readInt().toLong() and 0xffffffffL); data.seek(data.filePointer + count - 8); first = false }
                    else { require(type != 0x49484452 && type != 0x6163544c) { "Choose a single still image, not an animated PNG." }; data.seek(data.filePointer + count) }
                    data.skipBytes(4)
                    if (type == 0x49444154) idat = true
                    if (type == 0x49454e44) { require(count == 0L && idat && data.filePointer == data.length()) { "Invalid PNG end." }; return }
                }; error("PNG chunk limit exceeded.")
            }
            require(head[0] == 0xff.toByte() && head[1] == 0xd8.toByte()) { "Choose a PNG or JPEG still image." }; data.seek(2)
            repeat(4096) {
                require(data.readUnsignedByte() == 0xff) { "Invalid JPEG marker." }; var marker = data.readUnsignedByte(); while (marker == 0xff) marker = data.readUnsignedByte()
                require(marker !in listOf(0xd9, 0xda, 0x00)) { "JPEG dimensions are missing." }
                if (marker !in 0xd0..0xd8 && marker != 0x01) {
                    val length = data.readUnsignedShort(); require(length >= 2 && length - 2 <= data.length() - data.filePointer) { "Incomplete JPEG segment." }
                    if (marker in listOf(0xc0, 0xc1, 0xc2)) { require(length >= 8); data.readUnsignedByte(); val height = data.readUnsignedShort(); val width = data.readUnsignedShort(); dimensions(width.toLong(), height.toLong()); return }
                    data.seek(data.filePointer + length - 2)
                }
            }; error("JPEG marker limit exceeded.")
        }
    }
}
