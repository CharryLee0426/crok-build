package dev.chenli.crok.mobile.data

import android.annotation.SuppressLint
import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.graphics.createBitmap
import dev.chenli.crok.mobile.logic.AttachmentKind
import dev.chenli.crok.mobile.logic.AttachmentRules
import java.io.File
import java.io.InputStream
import java.time.LocalDateTime
import java.util.UUID
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** One pick for the composer: from the photo picker or the camera ([fromPhotos]: named by the time), or from Files. */
data class AttachmentPick(val uri: Uri, val fromPhotos: Boolean)

/** What preparing a pick gave. */
sealed interface PrepOutcome {
    data class Prepared(
        val kind: AttachmentKind,
        val name: String,
        val mimeType: String,
        val size: Long,
        val width: Int?,
        val height: Int?,
        val file: File,
        val thumbFile: File?,
    ) : PrepOutcome

    /** Over [AttachmentRules.MAX_FILE_BYTES]: not added. */
    data object TooBig : PrepOutcome

    data class Failed(val message: String?) : PrepOutcome
}

/**
 * Reads a pick and makes what is uploaded (relay/DESIGN.md §5 "Preparing an upload"): an image upright, at most 2048 px,
 * without metadata, as JPEG 0.85 (PNG for a PNG or one with transparency; a GIF up to 10 MB as it is), plus a 480 px
 * JPEG thumbnail on white; any other file as it is. The results go under the cache's `outbox`.
 */
class AttachmentPreparer(private val context: Context) {
    private val resolver: ContentResolver get() = context.contentResolver

    fun outboxDir(): File = File(context.cacheDir, OUTBOX)

    /** Drops what earlier runs left in the outbox (prepared, never sent or long sent). */
    fun clearOld(maxAgeMs: Long = 24 * 60 * 60 * 1000L) {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        outboxDir().listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
    }

    suspend fun prepare(pick: AttachmentPick, index: Int, at: LocalDateTime): PrepOutcome = withContext(Dispatchers.IO) {
        try {
            val (displayName, knownSize) = describe(pick.uri)
            val fallbackName = displayName ?: pick.uri.lastPathSegment?.substringAfterLast('/') ?: "file"
            val mime = AttachmentRules.mimeFor(fallbackName, resolver.getType(pick.uri))
            if (knownSize != null && knownSize > AttachmentRules.MAX_FILE_BYTES && !AttachmentRules.isImageType(mime)) {
                return@withContext PrepOutcome.TooBig
            }
            val dir = File(outboxDir(), UUID.randomUUID().toString()).apply { mkdirs() }
            // SVG is an image type no model reads and Android cannot decode: it goes as a file.
            if (AttachmentRules.isImageType(mime) && mime != "image/svg+xml") {
                prepareImage(pick, index, at, displayName, knownSize, mime, dir)?.let { return@withContext it }
            }
            prepareFile(pick.uri, fallbackName, knownSize, mime, dir)
        } catch (e: OutOfMemoryError) {
            PrepOutcome.Failed(e.message)
        } catch (e: Exception) {
            PrepOutcome.Failed(e.message)
        }
    }

    /** The pick's name and size as its provider says, when it does. */
    private fun describe(uri: Uri): Pair<String?, Long?> {
        var name: String? = null
        var size: Long? = null
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        }
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val file = uri.path?.let(::File)
            if (name == null) name = file?.name
            if (size == null) size = file?.length()
        }
        return name?.takeIf { it.isNotBlank() } to size
    }

    /** Null when Android cannot decode it: it goes as a file then. */
    private fun prepareImage(
        pick: AttachmentPick,
        index: Int,
        at: LocalDateTime,
        displayName: String?,
        knownSize: Long?,
        mime: String,
        dir: File,
    ): PrepOutcome? {
        fun nameFor(extension: String) = if (pick.fromPhotos || displayName == null) {
            AttachmentRules.photoName(at, index, extension)
        } else {
            AttachmentRules.withExtension(displayName, extension)
        }
        val encoding = AttachmentRules.encodingFor(mime, hasAlpha = false, byteCount = knownSize)
        if (encoding == AttachmentRules.Encoding.AsIs) {
            // A GIF that fits goes as it is (its animation kept); the model reads its first frame.
            val name = nameFor("gif")
            val file = File(dir, name)
            open(pick.uri).use { input -> file.outputStream().use { input.copyTo(it) } }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth <= 0) return null
            val firstFrame = decodeUpright(Uri.fromFile(file), AttachmentRules.THUMB_SIDE)
            val thumb = firstFrame?.let { writeThumbnail(it, dir) }
            firstFrame?.recycle()
            return PrepOutcome.Prepared(AttachmentKind.Image, name, "image/gif", file.length(), bounds.outWidth, bounds.outHeight, file, thumb)
        }
        val bitmap = decodeUpright(pick.uri, AttachmentRules.MAX_SIDE) ?: return null
        try {
            val chosen = AttachmentRules.encodingFor(mime.takeIf { it != "image/gif" }, bitmap.hasAlpha(), knownSize)
            val outMime = AttachmentRules.mimeFor(chosen, mime)
            val name = nameFor(AttachmentRules.extensionFor(outMime))
            val file = File(dir, name)
            file.outputStream().use { out ->
                if (chosen == AttachmentRules.Encoding.Png) {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                } else {
                    bitmap.compress(Bitmap.CompressFormat.JPEG, AttachmentRules.JPEG_QUALITY, out)
                }
            }
            if (file.length() > AttachmentRules.MAX_FILE_BYTES) return PrepOutcome.TooBig
            val thumb = writeThumbnail(bitmap, dir)
            return PrepOutcome.Prepared(AttachmentKind.Image, name, outMime, file.length(), bitmap.width, bitmap.height, file, thumb)
        } finally {
            bitmap.recycle()
        }
    }

    private fun prepareFile(uri: Uri, name: String, knownSize: Long?, mime: String, dir: File): PrepOutcome {
        if (knownSize != null && knownSize > AttachmentRules.MAX_FILE_BYTES) return PrepOutcome.TooBig
        val file = File(dir, name.substringAfterLast('/').ifBlank { "file" })
        var copied = 0L
        open(uri).use { input ->
            file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    copied += read
                    if (copied > AttachmentRules.MAX_FILE_BYTES) {
                        output.close()
                        dir.deleteRecursively()
                        return PrepOutcome.TooBig
                    }
                    output.write(buffer, 0, read)
                }
            }
        }
        return PrepOutcome.Prepared(AttachmentKind.File, file.name, mime, copied, null, null, file, null)
    }

    private fun open(uri: Uri): InputStream = resolver.openInputStream(uri) ?: error("Can’t read this file")

    /**
     * Decodes at most [maxSide] px on the longer side, with the picture's own orientation applied. The platform's
     * ExifInterface serves only Android 8 (ImageDecoder does the rest), where reading a stream's orientation is all it does.
     */
    @SuppressLint("ExifInterface")
    private fun decodeUpright(uri: Uri, maxSide: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // ImageDecoder applies the orientation itself and decodes straight to the smaller size (HEIC included).
            val source = ImageDecoder.createSource(resolver, uri)
            return runCatching {
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    val (w, h) = AttachmentRules.targetSize(info.size.width, info.size.height, maxSide)
                    decoder.setTargetSize(w, h)
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    decoder.memorySizePolicy = ImageDecoder.MEMORY_POLICY_DEFAULT
                }
            }.getOrNull()
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        open(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val decoded = open(uri).use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            ?: return null
        val orientation = runCatching {
            open(uri).use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val (w, h) = AttachmentRules.targetSize(decoded.width, decoded.height, maxSide)
        val matrix = Matrix().apply {
            postScale(w.toFloat() / decoded.width, h.toFloat() / decoded.height)
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    postRotate(90f)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    postRotate(270f)
                    postScale(-1f, 1f)
                }
            }
        }
        if (matrix.isIdentity) return decoded
        return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true).also {
            if (it !== decoded) decoded.recycle()
        }
    }

    /** At most 480 px, JPEG 0.7, transparency on white. */
    private fun writeThumbnail(source: Bitmap, dir: File): File? = runCatching {
        val (w, h) = AttachmentRules.targetSize(source.width, source.height, AttachmentRules.THUMB_SIDE)
        val thumb = createBitmap(w, h)
        Canvas(thumb).apply {
            drawColor(Color.WHITE)
            drawBitmap(source, null, Rect(0, 0, w, h), Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        }
        val file = File(dir, "thumb.jpg")
        file.outputStream().use { thumb.compress(Bitmap.CompressFormat.JPEG, AttachmentRules.THUMB_QUALITY, it) }
        thumb.recycle()
        file
    }.getOrNull()

    companion object {
        const val OUTBOX = "outbox"
    }
}
