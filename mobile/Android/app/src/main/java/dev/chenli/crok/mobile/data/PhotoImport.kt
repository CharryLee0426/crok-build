package dev.chenli.crok.mobile.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import androidx.core.graphics.scale
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/** The Photo session theme's picture: copied out of the photo picker's grant into the app's own files, downscaled. */
object PhotoImport {
    /** The longest side kept (mobile/DESIGN.md "Appearance"). */
    const val MAX_SIDE = 2048

    /** The target size for a [width] × [height] picture: the same when it fits, else scaled so its longest side fits. */
    fun targetSize(width: Int, height: Int, maxSide: Int = MAX_SIDE): Pair<Int, Int> {
        val longest = max(width, height)
        if (longest <= maxSide || longest <= 0) return width to height
        val scale = maxSide.toDouble() / longest
        return (width * scale).roundToInt().coerceAtLeast(1) to (height * scale).roundToInt().coerceAtLeast(1)
    }

    /** Decodes [uri], downscales it and writes it to [target] as JPEG. False when it is not a picture we can read. */
    fun store(context: Context, uri: Uri, target: File): Boolean = runCatching {
        val bitmap = decode(context, uri) ?: return false
        val temp = File(target.parentFile, target.name + ".tmp")
        temp.outputStream().use { out -> bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out) }
        bitmap.recycle()
        temp.renameTo(target)
    }.getOrDefault(false)

    private fun decode(context: Context, uri: Uri): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // ImageDecoder applies the photo's orientation and decodes straight to the smaller size.
            val source = ImageDecoder.createSource(context.contentResolver, uri)
            return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val (w, h) = targetSize(info.size.width, info.size.height)
                decoder.setTargetSize(w, h)
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2
        val decoded = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val (w, h) = targetSize(decoded.width, decoded.height)
        if (w == decoded.width && h == decoded.height) return decoded
        return decoded.scale(w, h).also { if (it !== decoded) decoded.recycle() }
    }

    /** The stored picture, or null when there is none. */
    fun load(file: File): Bitmap? = if (file.exists()) runCatching { BitmapFactory.decodeFile(file.path) }.getOrNull() else null
}
