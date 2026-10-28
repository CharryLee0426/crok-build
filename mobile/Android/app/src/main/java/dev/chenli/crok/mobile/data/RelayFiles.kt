package dev.chenli.crok.mobile.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import dev.chenli.crok.mobile.demo.DemoMedia
import dev.chenli.crok.mobile.logic.FileRef
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * The relay's photos and files on this phone (relay/DESIGN.md §5 "Photos and files in prompts"): a disk cache keyed by
 * storage id (a thumbnail by its own id), downloads and uploads with progress, decoded pictures in memory, and the
 * demo's `demo:` URLs. Storage URLs are stable, so a cached copy never needs checking again.
 */
object RelayFiles {
    private const val DIR = "relay-files"
    private const val MAX_CACHE_BYTES = 200L * 1024 * 1024
    private const val TRIM_TO_BYTES = 150L * 1024 * 1024
    private const val TIMEOUT_MS = 30_000
    private const val BUFFER = 64 * 1024
    private val safeKey = Regex("^[A-Za-z0-9_-]{1,100}$")

    fun cacheDir(context: Context): File = File(context.cacheDir, DIR).apply { mkdirs() }

    private fun fileFor(context: Context, key: String): File {
        val name = if (safeKey.matches(key)) key else sha1(key)
        return File(cacheDir(context), name)
    }

    private fun sha1(text: String): String =
        MessageDigest.getInstance("SHA-1").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    /** The cached copy of [key], or null. */
    fun cached(context: Context, key: String): File? = fileFor(context, key).takeIf { it.isFile && it.length() > 0 }

    /**
     * Keeps [source] as [key]: what this phone just uploaded, so its bubble shows the relay's copy at once when the
     * transcript item arrives.
     */
    fun store(context: Context, key: String, source: File) {
        runCatching {
            val target = fileFor(context, key)
            val temp = File(target.parentFile, target.name + ".part")
            source.copyTo(temp, overwrite = true)
            if (!temp.renameTo(target)) temp.delete()
            trim(context)
        }
    }

    /**
     * The file behind [ref] on this phone: a local file as it is; else the cached copy, the demo's bytes, or a download
     * ([onProgress] 0…1 while it runs). Null when it cannot be had.
     */
    suspend fun fetch(context: Context, ref: FileRef, onProgress: (Float) -> Unit = {}): File? = withContext(Dispatchers.IO) {
        if (ref.url.startsWith("file:")) return@withContext runCatching { File(URI(ref.url)) }.getOrNull()?.takeIf { it.isFile }
        cached(context, ref.cacheKey)?.let { return@withContext it }
        val target = fileFor(context, ref.cacheKey)
        when {
            ref.url.startsWith("demo:") -> DemoMedia.bytes(ref.url)?.let { bytes ->
                target.writeBytes(bytes)
                target
            }
            ref.url.startsWith("https:") || ref.url.startsWith("http:") -> runCatching { download(ref.url, target, onProgress) }.getOrNull()
            else -> null
        }
    }

    /** The bytes behind [ref] without a download: a local file, the cache, or the demo's. */
    fun fetchNow(context: Context, ref: FileRef): File? {
        if (ref.url.startsWith("file:")) return runCatching { File(URI(ref.url)) }.getOrNull()?.takeIf { it.isFile }
        cached(context, ref.cacheKey)?.let { return it }
        if (!ref.url.startsWith("demo:")) return null
        val bytes = DemoMedia.bytes(ref.url) ?: return null
        val target = fileFor(context, ref.cacheKey)
        return runCatching { target.writeBytes(bytes); target }.getOrNull()
    }

    private suspend fun download(url: String, target: File, onProgress: (Float) -> Unit): File {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS
        try {
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("Download failed ($code)")
            val total = connection.contentLengthLong
            val temp = File(target.parentFile, target.name + ".part")
            connection.inputStream.use { input ->
                temp.outputStream().use { output ->
                    val buffer = ByteArray(BUFFER)
                    var done = 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        done += read
                        if (total > 0) onProgress((done.toFloat() / total).coerceIn(0f, 1f))
                    }
                }
            }
            if (!temp.renameTo(target)) throw IOException("Could not keep the download")
            trim(target.parentFile!!)
            return target
        } finally {
            connection.disconnect()
        }
    }

    /** Uploads [file] to a `files:uploadUrl` URL (`POST` with its type); the answer is its storage id. */
    suspend fun upload(url: String, file: File, mime: String, onProgress: (Float) -> Unit): String {
        if (url.startsWith("demo:")) return DemoMedia.upload(file, mime, onProgress)
        return withContext(Dispatchers.IO) {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            try {
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(file.length())
                connection.setRequestProperty("Content-Type", mime)
                val total = file.length().coerceAtLeast(1)
                connection.outputStream.use { output ->
                    file.inputStream().use { input ->
                        val buffer = ByteArray(BUFFER)
                        var done = 0L
                        while (true) {
                            coroutineContext.ensureActive()
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            done += read
                            onProgress((done.toFloat() / total).coerceIn(0f, 1f))
                        }
                    }
                }
                val code = connection.responseCode
                if (code !in 200..299) throw IOException("Upload failed ($code)")
                val body = connection.inputStream.bufferedReader().use { it.readText() }
                RelayJson.decodeFromString(UploadResult.serializer(), body).storageId
            } finally {
                connection.disconnect()
            }
        }
    }

    private fun trim(context: Context) = trim(cacheDir(context))

    @Synchronized
    private fun trim(dir: File) {
        val files = dir.listFiles()?.filter { it.isFile } ?: return
        var total = files.sumOf { it.length() }
        if (total <= MAX_CACHE_BYTES) return
        for (file in files.sortedBy { it.lastModified() }) {
            if (total <= TRIM_TO_BYTES) break
            total -= file.length()
            file.delete()
        }
    }

    // ---- Decoded pictures ----

    private val memory = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 1024 / 8).toInt()) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount / 1024
    }

    private fun memoryKey(ref: FileRef, maxSide: Int) = "${ref.cacheKey}@$maxSide"

    /** A picture already decoded at this size, or null. */
    fun bitmapInMemory(ref: FileRef, maxSide: Int): Bitmap? = memory.get(memoryKey(ref, maxSide))

    /** [ref] decoded to at most [maxSide] px on its longer side, without a download (local, cached and demo files). */
    fun bitmapNow(context: Context, ref: FileRef, maxSide: Int): Bitmap? {
        bitmapInMemory(ref, maxSide)?.let { return it }
        val file = fetchNow(context, ref) ?: return null
        return decode(file, maxSide)?.also { memory.put(memoryKey(ref, maxSide), it) }
    }

    /** [ref] decoded to at most [maxSide] px on its longer side, downloaded first when needed. */
    suspend fun bitmap(context: Context, ref: FileRef, maxSide: Int): Bitmap? {
        bitmapInMemory(ref, maxSide)?.let { return it }
        val file = fetch(context, ref) ?: return null
        return withContext(Dispatchers.Default) { decode(file, maxSide) }?.also { memory.put(memoryKey(ref, maxSide), it) }
    }

    /** Uploads are upright already (the sender applied the orientation), so a plain sampled decode is enough. */
    fun decode(file: File, maxSide: Int): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }.getOrNull()
}
