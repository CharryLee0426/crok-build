package dev.chenli.crok.mobile.ui.common

import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.kyant.backdrop.backdrops.LayerBackdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.effects.vibrancy
import com.kyant.backdrop.highlight.Highlight
import com.kyant.backdrop.shadow.Shadow
import com.kyant.shapes.Capsule
import com.kyant.shapes.RoundedRectangle
import com.kyant.shapes.UnevenRoundedRectangle
import dev.chenli.crok.mobile.ui.theme.CrokColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme

/**
 * The Android side of iOS 26's Liquid Glass (relay/DESIGN.md §5, "Look"): bars and controls are glass over the content
 * that scrolls beneath them — the content is blurred and saturated, bent at the glass's edge (a lens), lit by a thin
 * rim and a specular highlight, under a light tint that keeps text readable. Kyant's backdrop library draws it: the
 * screen's content records itself into a layer ([glassContent]) and every glass surface draws that layer behind itself
 * with the effects ([glass]).
 *
 * What the device can do decides how much of it there is ([GlassLevel]): the lens and the highlight need runtime shaders
 * (Android 13), the blur needs render effects (Android 12); before that the glass is a translucent frosted surface with
 * a drawn rim.
 */
enum class GlassLevel {
    /** Android 13+: blur, lens refraction, highlight. */
    Liquid,

    /** Android 12: blur under a thicker tint, no lens. */
    Frosted,

    /** Android 11 and older: no backdrop effects, a nearly opaque tint and a drawn rim. */
    Tinted;

    companion object {
        val device: GlassLevel = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> Liquid
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> Frosted
            else -> Tinted
        }
    }
}

/** The screen's content layer that glass surfaces read; null outside a screen that set one up. */
val LocalGlassBackdrop = compositionLocalOf<LayerBackdrop?> { null }

/** Lets a test pick the level (screenshots of the fallback); the device's own level otherwise. */
val LocalGlassLevel = compositionLocalOf { GlassLevel.device }

/** iOS's continuous-corner shapes, which the lens bends along. */
object GlassShapes {
    val capsule: Shape = Capsule()

    fun rounded(radius: Dp): Shape = RoundedRectangle(radius)

    /** A bar that runs to the screen's edges: square corners, so only the inner edge refracts. */
    val bar: Shape = UnevenRoundedRectangle()

    /** The top bar's panel: square at the top (under the status bar), softly rounded where the content shows. */
    val topPanel: Shape = UnevenRoundedRectangle(bottomStart = 22.dp, bottomEnd = 22.dp)
}

/** A content layer for glass to read: remember it once per screen and put it on the content with [glassContent]. */
@Composable
fun rememberGlassBackdrop(background: Color = CrokTheme.colors.screen): LayerBackdrop {
    // Paint the screen's colour first: where the content leaves gaps the glass must see the page, not transparency.
    return rememberLayerBackdrop {
        drawRect(background)
        drawContent()
    }
}

/** Marks the content glass surfaces show through, and makes [backdrop] the one inner glass uses. */
fun Modifier.glassContent(backdrop: LayerBackdrop): Modifier = layerBackdrop(backdrop)

/** Provides [backdrop] to the glass inside [content] (floating buttons, the composer). */
@Composable
fun ProvideGlass(backdrop: LayerBackdrop, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalGlassBackdrop provides backdrop, content = content)
}

/** How a glass surface looks: a bar is flatter and more opaque than a floating control. */
enum class GlassStyle {
    /** Top bars and the composer bar: strong blur so text beneath never fights the title. */
    Bar,

    /** Floating controls (tab bar, buttons, the composer capsule): clearer glass with a shadow. */
    Floating,

    /** A tinted control (the selected tab, the Menu pill): the glass takes [tint] as its colour. */
    Tinted,
}

/**
 * Draws [backdrop] (the content beneath) as glass in [shape]. Without a backdrop (a screen without one, a preview) it
 * falls back to the frosted surface. Never inside the content that [backdrop] records: the layer would draw itself
 * without end (pass `backdrop = null` there).
 */
@Composable
fun Modifier.glass(
    shape: Shape,
    style: GlassStyle = GlassStyle.Floating,
    tint: Color? = null,
    backdrop: LayerBackdrop? = LocalGlassBackdrop.current,
): Modifier {
    val colors = CrokTheme.colors
    val level = LocalGlassLevel.current
    val surface = surfaceColor(colors, style, tint, level)
    val rim = colors.glassRim
    if (backdrop == null || level == GlassLevel.Tinted) {
        // No backdrop shaders: a translucent frosted surface with a drawn rim and highlight.
        return this
            .then(if (style == GlassStyle.Bar) Modifier else Modifier.dropShadow(shape, colors))
            .drawWithContent {
                val outline = shape.createOutline(size, layoutDirection, this)
                drawOutline(outline, surface)
                drawContent()
                drawRim(outline, rim, colors.isDark)
            }
    }
    val density = LocalDensity.current
    val blurPx = with(density) { (if (style == GlassStyle.Bar) 18.dp else 6.dp).toPx() }
    val refractionHeight = with(density) { (if (style == GlassStyle.Bar) 10.dp else 14.dp).toPx() }
    val refractionAmount = with(density) { (if (style == GlassStyle.Bar) 14.dp else 22.dp).toPx() }
    return this.drawBackdrop(
        backdrop = backdrop,
        shape = { shape },
        effects = {
            vibrancy()
            blur(blurPx)
            // The lens (Android 13+); the library skips it below that.
            lens(refractionHeight, refractionAmount, depthEffect = style != GlassStyle.Bar)
        },
        highlight = {
            if (style == GlassStyle.Bar) Highlight.Plain.copy(alpha = if (colors.isDark) 0.35f else 0.6f)
            else Highlight.Default.copy(alpha = if (colors.isDark) 0.55f else 0.9f)
        },
        shadow = if (style == GlassStyle.Bar) null else ({ Shadow(radius = 18.dp, color = Color.Black.copy(alpha = if (colors.isDark) 0.3f else 0.1f)) }),
        onDrawSurface = { drawRect(surface) },
    )
}

private fun surfaceColor(colors: CrokColors, style: GlassStyle, tint: Color?, level: GlassLevel): Color {
    // Thicker where there is less glass to see through: the tint has to do the blur's job.
    val alpha = when (level) {
        GlassLevel.Liquid -> when (style) {
            GlassStyle.Bar -> if (colors.isDark) 0.62f else 0.66f
            GlassStyle.Floating -> if (colors.isDark) 0.42f else 0.5f
            GlassStyle.Tinted -> 0.86f
        }
        GlassLevel.Frosted -> when (style) {
            GlassStyle.Bar -> 0.8f
            GlassStyle.Floating -> 0.7f
            GlassStyle.Tinted -> 0.92f
        }
        GlassLevel.Tinted -> when (style) {
            GlassStyle.Bar -> 0.94f
            GlassStyle.Floating -> 0.92f
            GlassStyle.Tinted -> 1f
        }
    }
    return (tint ?: colors.glassTint).copy(alpha = alpha)
}

/** The fallback's shadow under a floating control: only outside the shape, so the translucent surface stays clear. */
private fun Modifier.dropShadow(shape: Shape, colors: CrokColors): Modifier = drawWithContent {
    val outline = shape.createOutline(size, layoutDirection, this)
    val shadow = Color.Black.copy(alpha = if (colors.isDark) 0.28f else 0.08f)
    clipPath(outline.toPath(), ClipOp.Difference) {
        for (i in 3 downTo 1) {
            translate(0f, i * 1.5f.dp.toPx()) { drawOutline(outline, shadow.copy(alpha = shadow.alpha / i)) }
        }
    }
    drawContent()
}

private fun Outline.toPath(): Path = when (this) {
    is Outline.Rectangle -> Path().apply { addRect(rect) }
    is Outline.Rounded -> Path().apply { addRoundRect(roundRect) }
    is Outline.Generic -> path
}

/** A light rim, brightest at the top-left like the light falling on glass. */
private fun DrawScope.drawRim(outline: Outline, rim: Color, dark: Boolean) {
    val strong = rim.copy(alpha = if (dark) 0.28f else 0.85f)
    val faint = rim.copy(alpha = if (dark) 0.06f else 0.25f)
    val brush = Brush.linearGradient(listOf(strong, faint, strong.copy(alpha = strong.alpha * 0.5f)), Offset.Zero, Offset(size.width, size.height))
    val stroke = Stroke(width = 1.dp.toPx())
    drawPath(outline.toPath(), brush, style = stroke)
}

/** A round glass button (scroll to bottom, compose). */
@Composable
fun GlassCircle(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
    tint: Color? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier
            .size(size)
            .glass(GlassShapes.capsule, if (tint != null) GlassStyle.Tinted else GlassStyle.Floating, tint)
            .clip(GlassShapes.capsule)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
        content = content,
    )
}
