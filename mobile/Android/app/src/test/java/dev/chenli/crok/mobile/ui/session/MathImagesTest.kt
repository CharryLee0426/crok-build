package dev.chenli.crok.mobile.ui.session

import androidx.test.core.app.ApplicationProvider
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.logic.MathExtractor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class MathImagesTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    @Test
    fun drawsTheShowcaseAndRefusesWhatItCannotParse() {
        val spans = MathExtractor.extract(DemoData.markdownShowcase).spans
        // Before JLatexMath has started nothing is drawn (the reply shows TeX source meanwhile).
        if (!MathImages.ready) assertNull(MathImages.render(context, "x", false, 42f))
        val started = System.nanoTime()
        MathImages.warmUp(context)
        val warmUpMs = (System.nanoTime() - started) / 1_000_000.0
        assertTrue(MathImages.ready)
        val first = System.nanoTime()
        val drawn = spans.associateWith { MathImages.render(context, it.tex, it.display, 42f) }
        val drawMs = (System.nanoTime() - first) / 1_000_000.0
        val unsupported = drawn.filterValues { it == null }.keys.map { it.tex }
        assertEquals(listOf("\\unknowncommand{x}"), unsupported)
        assertNotNull(drawn[spans.first()])
        val again = System.nanoTime()
        spans.forEach { MathImages.render(context, it.tex, it.display, 42f) }
        val cachedMs = (System.nanoTime() - again) / 1_000_000.0
        println(
            "math: start-up %.1f ms, the showcase's %d formulas %.1f ms, again from cache %.2f ms"
                .format(warmUpMs, spans.size, drawMs, cachedMs),
        )
        // Depth below the baseline (JLatexMath's box includes a small bottom inset): a fraction reaches further than `x`.
        assertTrue(MathImages.render(context, "\\frac{a}{b}", false, 42f)!!.depth > MathImages.render(context, "x", false, 42f)!!.depth)
        assertNull(MathImages.render(context, "\\frac{a}{", false, 42f))
    }
}
