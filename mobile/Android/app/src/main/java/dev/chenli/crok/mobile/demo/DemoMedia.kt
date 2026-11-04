package dev.chenli.crok.mobile.demo

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import androidx.core.graphics.createBitmap
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.delay

/**
 * The demo relay's photos and files, without a network: `demo://image/<name>` pictures drawn on the phone,
 * `demo://file/<name>` documents, and `demo://blob/<id>` for what the demo account uploads (kept in memory).
 */
object DemoMedia {
    const val UPLOAD_URL = "demo://upload"

    /** The demo session's pictures: name → (width, height, top colour, bottom colour). */
    private val pictures = mapOf(
        "onboarding-1.png" to Picture(780, 1688, 0xFF3390EC.toInt(), 0xFF7B5CFF.toInt(), screen = true),
        "onboarding-2.png" to Picture(780, 1688, 0xFF20B486.toInt(), 0xFF3390EC.toInt(), screen = true),
        "whiteboard.jpg" to Picture(1600, 1200, 0xFFF4EDE1.toInt(), 0xFFE4D8C4.toInt(), screen = false),
    )

    private class Picture(val width: Int, val height: Int, val top: Int, val bottom: Int, val screen: Boolean)

    private val rendered = ConcurrentHashMap<String, ByteArray>()
    private val blobs = ConcurrentHashMap<String, Pair<ByteArray, String>>()

    fun imageUrl(name: String) = "demo://image/$name"

    fun fileUrl(name: String) = "demo://file/$name"

    fun size(name: String): Pair<Int, Int>? = pictures[name]?.let { it.width to it.height }

    /** The bytes behind a `demo:` URL, or null. */
    fun bytes(url: String): ByteArray? {
        val path = url.removePrefix("demo://")
        return when {
            path.startsWith("image/") -> path.removePrefix("image/").let { name -> rendered.getOrPut(name) { draw(name) ?: return null } }
            path.startsWith("file/") -> pdf(path.removePrefix("file/"))
            path.startsWith("blob/") -> blobs[path.removePrefix("blob/")]?.first
            else -> null
        }
    }

    /** The type of an upload this demo account made. */
    fun blobType(id: String): String? = blobs[id]?.second

    fun blobSize(id: String): Long = blobs[id]?.first?.size?.toLong() ?: 0

    fun blobUrl(id: String) = "demo://blob/$id"

    /** An upload to the demo relay: kept in memory, with a little progress to look at. */
    suspend fun upload(file: File, mime: String, onProgress: (Float) -> Unit): String {
        val bytes = file.readBytes()
        for (step in 1..5) {
            delay(80)
            onProgress(step / 5f)
        }
        val id = "demo-blob-${UUID.randomUUID()}"
        blobs[id] = bytes to mime
        return id
    }

    private fun draw(name: String): ByteArray? {
        val picture = pictures[name] ?: return null
        val bitmap = createBitmap(picture.width, picture.height)
        val canvas = Canvas(bitmap)
        val w = picture.width.toFloat()
        val h = picture.height.toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f, 0f, w * 0.3f, h, picture.top, picture.bottom, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w, h, paint)
        paint.shader = null
        if (picture.screen) {
            // A phone screen mock-up: a status bar, a big round illustration, a title, two lines of text, a button.
            paint.color = 0x33FFFFFF
            canvas.drawRoundRect(RectF(w * 0.08f, h * 0.04f, w * 0.92f, h * 0.07f), 20f, 20f, paint)
            paint.color = 0x55FFFFFF
            canvas.drawCircle(w / 2, h * 0.33f, w * 0.28f, paint)
            paint.color = 0xCCFFFFFF.toInt()
            canvas.drawCircle(w / 2, h * 0.33f, w * 0.14f, paint)
            paint.color = 0xF2FFFFFF.toInt()
            canvas.drawRoundRect(RectF(w * 0.18f, h * 0.58f, w * 0.82f, h * 0.62f), 18f, 18f, paint)
            paint.color = 0x99FFFFFF.toInt()
            canvas.drawRoundRect(RectF(w * 0.12f, h * 0.66f, w * 0.88f, h * 0.68f), 12f, 12f, paint)
            canvas.drawRoundRect(RectF(w * 0.22f, h * 0.70f, w * 0.78f, h * 0.72f), 12f, 12f, paint)
            paint.color = 0xFFFFFFFF.toInt()
            canvas.drawRoundRect(RectF(w * 0.1f, h * 0.84f, w * 0.9f, h * 0.9f), 60f, 60f, paint)
        } else {
            // A whiteboard sketch: boxes joined by arrows.
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = w * 0.008f
            paint.color = 0xFF2B5278.toInt()
            canvas.drawRoundRect(RectF(w * 0.08f, h * 0.2f, w * 0.34f, h * 0.42f), 24f, 24f, paint)
            canvas.drawRoundRect(RectF(w * 0.4f, h * 0.2f, w * 0.66f, h * 0.42f), 24f, 24f, paint)
            canvas.drawRoundRect(RectF(w * 0.72f, h * 0.2f, w * 0.94f, h * 0.42f), 24f, 24f, paint)
            paint.color = 0xFFD94F4F.toInt()
            canvas.drawLine(w * 0.34f, h * 0.31f, w * 0.4f, h * 0.31f, paint)
            canvas.drawLine(w * 0.66f, h * 0.31f, w * 0.72f, h * 0.31f, paint)
            paint.color = 0xFF20A060.toInt()
            canvas.drawRoundRect(RectF(w * 0.3f, h * 0.6f, w * 0.7f, h * 0.82f), 24f, 24f, paint)
            canvas.drawLine(w * 0.53f, h * 0.42f, w * 0.5f, h * 0.6f, paint)
        }
        val out = ByteArrayOutputStream()
        val format = if (name.endsWith(".png")) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        bitmap.compress(format, 85, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    /** A one-page PDF saying what it is. */
    private fun pdf(name: String): ByteArray {
        val text = "Crok demo: $name"
        val stream = "BT /F1 24 Tf 72 720 Td (${text.replace("(", "\\(").replace(")", "\\)")}) Tj ET"
        val objects = listOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length ${stream.length} >>\nstream\n$stream\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        )
        val out = StringBuilder("%PDF-1.4\n")
        val offsets = ArrayList<Int>()
        objects.forEachIndexed { index, body ->
            offsets += out.length
            out.append("${index + 1} 0 obj\n$body\nendobj\n")
        }
        val xref = out.length
        out.append("xref\n0 ${objects.size + 1}\n0000000000 65535 f \n")
        offsets.forEach { out.append(String.format(Locale.ROOT, "%010d 00000 n \n", it)) }
        out.append("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n")
        return out.toString().toByteArray(Charsets.US_ASCII)
    }

    /** The demo PDF's size, as the relay would list it. */
    fun fileSize(name: String): Long = pdf(name).size.toLong()
}
