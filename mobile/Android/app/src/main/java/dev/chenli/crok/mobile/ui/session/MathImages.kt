package dev.chenli.crok.mobile.ui.session

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.collection.LruCache
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.createBitmap
import kotlin.math.roundToInt
import ru.noties.jlatexmath.JLatexMathAndroid
import ru.noties.jlatexmath.JLatexMathDrawable

/**
 * LaTeX drawn by JLatexMath (relay/DESIGN.md §5 "Replies in Markdown"): white on transparent, tinted with the text
 * colour when drawn, so one bitmap serves light and dark. Bitmaps are cached by TeX and size, failures too, so a
 * streaming reply redraws only formulas it has not seen. TeX JLatexMath cannot parse returns null (the caller shows the
 * source instead).
 */
object MathImages {
    /** A drawn formula; [depth] is how far it reaches below its baseline, in pixels. */
    class Rendered(val image: ImageBitmap, val depth: Int) {
        val width: Int get() = image.width
        val height: Int get() = image.height
        val ascent: Int get() = height - depth
    }

    private val failed = Any()
    private const val MAX_PIXELS = 4_000_000

    private val cache = object : LruCache<String, Any>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Any): Int = (value as? Rendered)?.let { it.width * it.height * 4 } ?: 64
    }

    /** JLatexMath keeps global state (fonts, symbol tables): one formula at a time. */
    private val lock = Any()
    private var initialized = false
    private val readyState = mutableStateOf(false)

    /**
     * Whether JLatexMath has started (its first formula loads fonts and symbol tables, ~0.4 s). Until then [render]
     * returns null and replies show the TeX source; composables that read this redraw once it flips.
     */
    val ready: Boolean get() = readyState.value

    /** Starts JLatexMath; blocking, so call it off the main thread (MarkdownText does, the first time it sees math). */
    fun warmUp(context: Context) {
        if (readyState.value) return
        synchronized(lock) { draw(context, "x", display = false, sizePx = 32f) }
        readyState.value = true
    }

    fun render(context: Context, tex: String, display: Boolean, sizePx: Float): Rendered? {
        if (!readyState.value) return null
        val key = (if (display) "D" else "I") + sizePx.roundToInt() + ':' + tex
        cache[key]?.let { return it as? Rendered }
        val rendered = synchronized(lock) { draw(context, tex, display, sizePx) }
        cache.put(key, rendered ?: failed)
        return rendered
    }

    private fun draw(context: Context, tex: String, display: Boolean, sizePx: Float): Rendered? {
        if (!initialized) {
            // Normally done by the library's init provider; Robolectric and odd process starts may skip it.
            JLatexMathAndroid.init(context.applicationContext ?: context)
            initialized = true
        }
        return try {
            // The drawable always typesets in display style; inline math asks for text style itself.
            val drawable = JLatexMathDrawable.builder(if (display) tex else "\\textstyle $tex")
                .textSize(sizePx)
                .color(android.graphics.Color.WHITE)
                .align(JLatexMathDrawable.ALIGN_LEFT)
                .build()
            val width = drawable.intrinsicWidth
            val height = drawable.intrinsicHeight
            if (width <= 0 || height <= 0 || width.toLong() * height > MAX_PIXELS) return null
            val bitmap = createBitmap(width, height)
            drawable.draw(Canvas(bitmap))
            Rendered(trimSides(bitmap).asImageBitmap(), drawable.icon().iconDepth.coerceIn(0, height - 1))
        } catch (_: Exception) {
            null
        } catch (_: StackOverflowError) {
            null
        }
    }

    /**
     * JLatexMath's box carries blank columns at its sides, which read as stray spaces next to the text ("0 ," and
     * "x -axis"); keep only the ink, plus a pixel for antialiasing.
     */
    private fun trimSides(bitmap: Bitmap): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        fun inked(x: Int): Boolean {
            for (y in 0 until height) if (pixels[y * width + x] ushr 24 != 0) return true
            return false
        }
        var left = 0
        while (left < width && !inked(left)) left++
        if (left == width) return bitmap
        var right = width - 1
        while (right > left && !inked(right)) right--
        left = (left - 1).coerceAtLeast(0)
        right = (right + 1).coerceAtMost(width - 1)
        if (left == 0 && right == width - 1) return bitmap
        return Bitmap.createBitmap(bitmap, left, 0, right - left + 1, height)
    }
}
