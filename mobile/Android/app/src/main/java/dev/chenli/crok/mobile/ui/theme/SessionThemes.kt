package dev.chenli.crok.mobile.ui.theme

import android.os.Build
import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.Air
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.Backpack
import androidx.compose.material.icons.outlined.Bed
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.BugReport
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.CardGiftcard
import androidx.compose.material.icons.outlined.Casino
import androidx.compose.material.icons.outlined.Celebration
import androidx.compose.material.icons.outlined.ChangeHistory
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.CloudQueue
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Coffee
import androidx.compose.material.icons.outlined.CrueltyFree
import androidx.compose.material.icons.outlined.DataObject
import androidx.compose.material.icons.outlined.Diamond
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.DownhillSkiing
import androidx.compose.material.icons.outlined.Eco
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.EmojiNature
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Fireplace
import androidx.compose.material.icons.outlined.FlutterDash
import androidx.compose.material.icons.outlined.Functions
import androidx.compose.material.icons.outlined.Gamepad
import androidx.compose.material.icons.outlined.Grass
import androidx.compose.material.icons.outlined.Hexagon
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Landscape
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Light
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.LocalCafe
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.LocalFlorist
import androidx.compose.material.icons.outlined.Mail
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.MilitaryTech
import androidx.compose.material.icons.outlined.MusicNote
import androidx.compose.material.icons.outlined.NightsStay
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material.icons.outlined.Park
import androidx.compose.material.icons.outlined.Pentagon
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Restaurant
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Science
import androidx.compose.material.icons.outlined.SentimentSatisfied
import androidx.compose.material.icons.outlined.Spa
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.SportsScore
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material.icons.outlined.Straighten
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.Thermostat
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.VideogameAsset
import androidx.compose.material.icons.outlined.VolunteerActivism
import androidx.compose.material.icons.outlined.WaterDrop
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.material.icons.outlined.Weekend
import androidx.compose.material.icons.outlined.WorkspacePremium
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.VectorPainter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.core.graphics.scale
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.ThemeGradient
import java.util.Random

/** One light-or-dark half of a session theme: the four gradient colours and the person's bubbles (ARGB). */
@Immutable
data class ThemeVariant(
    val gradient: List<Long>,
    val out: Long,
    val outText: Long,
    val outMeta: Long,
)

/**
 * A session theme (mobile/DESIGN.md "Session themes"): Telegram's chat themes, drawn by Crok. `none` is the plain Crok
 * Day / Night background and `photo` the chosen picture; both keep the default bubbles.
 */
@Immutable
data class SessionThemeSpec(
    val id: String,
    @StringRes val name: Int,
    val emoji: String,
    val light: ThemeVariant? = null,
    val dark: ThemeVariant? = null,
    val glyphs: List<ImageVector> = emptyList(),
) {
    val drawn: Boolean get() = light != null && dark != null

    fun variant(dark: Boolean): ThemeVariant? = if (dark) this.dark else light
}

private fun v(c0: Long, c1: Long, c2: Long, c3: Long, out: Long, outText: Long, outMeta: Long) =
    ThemeVariant(listOf(c0, c1, c2, c3), out, outText, outMeta)

object SessionThemes {
    const val NONE = "none"
    const val PHOTO = "photo"

    private val o = Icons.Outlined

    val all: List<SessionThemeSpec> = listOf(
        SessionThemeSpec(NONE, R.string.session_theme_none, "✕"),
        SessionThemeSpec(
            "classic", R.string.session_theme_classic, "🌿",
            v(0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884, 0xFFEFFDDE, 0xFF000000, 0xFF4FAE4E),
            v(0xFF2E5B46, 0xFF14322A, 0xFF3F6A3A, 0xFF1D4236, 0xFF2F5D50, 0xFFFFFFFF, 0xFFA5E0C9),
            listOf(
                o.Terminal, o.Code, o.DataObject, o.Memory, o.BugReport, o.Build, o.Tag, o.Functions, o.Keyboard, o.Dns,
                o.Bolt, Icons.AutoMirrored.Outlined.Send, o.Cloud, o.AutoAwesome, o.Laptop, o.LocalCafe,
            ),
        ),
        SessionThemeSpec(
            "home", R.string.session_theme_home, "🏠",
            v(0xFFF9D9A9, 0xFFF2B880, 0xFFFCE8C8, 0xFFE9A877, 0xFFFFE3C2, 0xFF000000, 0xFFC4772F),
            v(0xFF6B4220, 0xFF3A2412, 0xFF7D5026, 0xFF4C2E17, 0xFF7A4A22, 0xFFFFFFFF, 0xFFF5C99A),
            listOf(o.Home, o.Weekend, o.Light, o.Coffee, o.Key, o.Eco, o.Bed, o.Restaurant, o.Fireplace, o.WbSunny, o.FavoriteBorder),
        ),
        SessionThemeSpec(
            "duck", R.string.session_theme_duck, "🐥",
            v(0xFFFFF3A3, 0xFFD9F29B, 0xFFFFE07A, 0xFFBFE59A, 0xFFFFF4B8, 0xFF000000, 0xFFB89A00),
            v(0xFF5E5A1A, 0xFF33461F, 0xFF6E5E14, 0xFF2C3F1D, 0xFF6B5E12, 0xFFFFFFFF, 0xFFF2E38A),
            listOf(o.FlutterDash, o.Eco, o.WbSunny, o.Cloud, o.WaterDrop, o.Grass, o.EmojiNature, o.CrueltyFree, o.LocalFlorist, o.StarBorder),
        ),
        SessionThemeSpec(
            "snowman", R.string.session_theme_snowman, "⛄",
            v(0xFFE3F2FF, 0xFFB8DCFB, 0xFFF2F8FF, 0xFFA8CDF2, 0xFFD8EEFF, 0xFF000000, 0xFF3390EC),
            v(0xFF1E3D63, 0xFF11233B, 0xFF2A4B78, 0xFF173052, 0xFF24507E, 0xFFFFFFFF, 0xFFA8CCF7),
            listOf(o.AcUnit, o.CloudQueue, o.Landscape, o.Air, o.StarBorder, o.NightsStay, o.Thermostat, o.AutoAwesome, o.LocalCafe, o.DownhillSkiing),
        ),
        SessionThemeSpec(
            "diamond", R.string.session_theme_diamond, "💎",
            v(0xFFA8E6E2, 0xFF9AC7F5, 0xFFC9F0E4, 0xFFB6B4F2, 0xFFD4F4EE, 0xFF000000, 0xFF1F9C8F),
            v(0xFF16595C, 0xFF153562, 0xFF1F5E57, 0xFF353070, 0xFF1E6B6B, 0xFFFFFFFF, 0xFF9FEDE2),
            listOf(o.Diamond, o.AutoAwesome, o.WorkspacePremium, o.Verified, o.StarBorder, o.ChangeHistory, o.Hexagon, o.Pentagon, o.MilitaryTech),
        ),
        SessionThemeSpec(
            "teacher", R.string.session_theme_teacher, "👨‍🏫",
            v(0xFFCFE8C9, 0xFF9FD3C7, 0xFFE7F0C3, 0xFFB4D9A6, 0xFFE3F4D9, 0xFF000000, 0xFF4C9A4A),
            v(0xFF2B4D35, 0xFF1A3628, 0xFF3E5832, 0xFF22473F, 0xFF2E5A38, 0xFFFFFFFF, 0xFFB4E3A8),
            listOf(
                Icons.AutoMirrored.Outlined.MenuBook, o.Edit, o.School, o.Straighten, o.Functions, o.Science, o.Public, o.Backpack,
                o.AttachFile, o.Lightbulb, o.AutoStories,
            ),
        ),
        SessionThemeSpec(
            "tulip", R.string.session_theme_tulip, "🌷",
            v(0xFFFFD1DC, 0xFFF7A8C4, 0xFFFFE4EC, 0xFFF2B6D0, 0xFFFFDDE7, 0xFF000000, 0xFFD9467A),
            v(0xFF6E2447, 0xFF43162D, 0xFF852E55, 0xFF561D38, 0xFF7A2A4E, 0xFFFFFFFF, 0xFFFFB3CE),
            listOf(o.LocalFlorist, o.Eco, o.FavoriteBorder, o.WbSunny, o.EmojiNature, o.WaterDrop, o.AutoAwesome, o.Spa, o.Cloud, o.StarBorder),
        ),
        SessionThemeSpec(
            "purple", R.string.session_theme_purple, "💜",
            v(0xFFE2D4FA, 0xFFC7B2F2, 0xFFF0E6FF, 0xFFD5B8EE, 0xFFEADFFF, 0xFF000000, 0xFF8A5CD8),
            v(0xFF45276F, 0xFF29184B, 0xFF5A318C, 0xFF371F60, 0xFF563590, 0xFFFFFFFF, 0xFFD3BCFF),
            listOf(
                o.FavoriteBorder, o.AutoAwesome, o.StarBorder, o.NightsStay, o.MusicNote, o.VolunteerActivism, o.Celebration,
                o.CardGiftcard, o.Mail, o.SentimentSatisfied,
            ),
        ),
        SessionThemeSpec(
            "christmas", R.string.session_theme_christmas, "🎄",
            v(0xFFD7EBD3, 0xFFF3D8C5, 0xFFC3E0C9, 0xFFF1E3B3, 0xFFE2F2DC, 0xFF000000, 0xFF3D8E48),
            v(0xFF1D472D, 0xFF572222, 0xFF173A24, 0xFF4C3A15, 0xFF2D5C3A, 0xFFFFFFFF, 0xFFB5E6BE),
            listOf(
                o.CardGiftcard, o.AcUnit, o.StarBorder, o.NotificationsNone, o.Park, o.LocalFireDepartment, o.AutoAwesome,
                o.NightsStay, o.LocalCafe, o.MusicNote,
            ),
        ),
        SessionThemeSpec(
            "game", R.string.session_theme_game, "🎮",
            v(0xFFC9D6FF, 0xFFE2C9FF, 0xFFB8F0FF, 0xFFD6E4FF, 0xFFDDE4FF, 0xFF000000, 0xFF5B6CF0),
            v(0xFF272E73, 0xFF451E77, 0xFF17456F, 0xFF33216F, 0xFF3B3F9E, 0xFFFFFFFF, 0xFFC3C8FF),
            listOf(
                o.SportsEsports, o.Gamepad, o.VideogameAsset, o.EmojiEvents, o.Bolt, o.StarBorder, o.SportsScore,
                o.FavoriteBorder, o.Extension, o.Casino, o.WorkspacePremium, o.Keyboard,
            ),
        ),
        SessionThemeSpec(PHOTO, R.string.session_theme_photo, "🖼"),
    )

    fun byId(id: String): SessionThemeSpec = all.firstOrNull { it.id == id } ?: all.first()

    /** The cards of Profile › Appearance: Photo only once a photo was chosen. */
    fun cards(hasPhoto: Boolean): List<SessionThemeSpec> = if (hasPhoto) all else all.filter { it.id != PHOTO }
}

/** What Profile › Appearance chose, as the session screens read it ([LocalSessionAppearance]). */
@Immutable
data class SessionAppearance(
    val themeId: String = SessionThemes.NONE,
    val blur: Boolean = false,
    val photo: ImageBitmap? = null,
) {
    /** The theme to draw: Photo falls back to No Theme while there is no picture. */
    val theme: SessionThemeSpec
        get() = SessionThemes.byId(themeId).let { if (it.id == SessionThemes.PHOTO && photo == null) SessionThemes.byId(SessionThemes.NONE) else it }
}

val LocalSessionAppearance = staticCompositionLocalOf { SessionAppearance() }

/** The person's bubbles and the service capsules on a session background ([LocalSessionColors]). */
@Immutable
data class SessionColors(
    val bubbleOut: Color,
    val onBubbleOut: Color,
    /** Time and label on the person's bubble. */
    val outMeta: Color,
    /** ✓ and ✓✓ on the person's bubble. */
    val outTick: Color,
    /** Day headers and notices on a themed background (null: the plain pills). */
    val serviceBackground: Color? = null,
    val serviceText: Color? = null,
)

val LocalSessionColors = staticCompositionLocalOf<SessionColors?> { null }

object SessionTheme {
    /** The colours for [appearance] in the current light or dark mode. */
    fun colors(appearance: SessionAppearance, colors: CrokColors): SessionColors {
        val theme = appearance.theme
        val variant = theme.variant(colors.isDark)
        val service = theme.id != SessionThemes.NONE
        val serviceBackground = if (service) Color.Black.copy(alpha = if (colors.isDark) 0.40f else 0.22f) else null
        val serviceText = if (service) Color.White else null
        if (variant == null) {
            return SessionColors(
                bubbleOut = colors.bubbleOut,
                onBubbleOut = colors.onBubbleOut,
                outMeta = if (colors.isDark) colors.onBubbleOut.copy(alpha = 0.6f) else colors.textTertiary,
                // Accent ticks on the light bubble; on the dark blue one the accent would vanish, so a light blue-white.
                outTick = if (colors.isDark) Color(0xFFB8D8FF) else colors.accent,
                serviceBackground = serviceBackground,
                serviceText = serviceText,
            )
        }
        return SessionColors(
            bubbleOut = Color(variant.out),
            onBubbleOut = Color(variant.outText),
            outMeta = Color(variant.outMeta),
            outTick = Color(variant.outMeta),
            serviceBackground = serviceBackground,
            serviceText = serviceText,
        )
    }

    val current: SessionColors
        @Composable @ReadOnlyComposable get() = LocalSessionColors.current ?: colors(LocalSessionAppearance.current, CrokTheme.colors)
}

/** Gives the screen inside the session colours of the chosen theme. */
@Composable
fun ProvideSessionColors(content: @Composable () -> Unit) {
    val appearance = LocalSessionAppearance.current
    val colors = CrokTheme.colors
    val session = remember(appearance, colors) { SessionTheme.colors(appearance, colors) }
    CompositionLocalProvider(LocalSessionColors provides session, content = content)
}

/** A copy [factor] times smaller on each side (the blur fallback). */
private fun ImageBitmap.shrunk(factor: Int): ImageBitmap {
    val source = asAndroidBitmap()
    val width = (source.width / factor).coerceAtLeast(1)
    val height = (source.height / factor).coerceAtLeast(1)
    return source.scale(width, height).asImageBitmap()
}

/** The near-black under a dark theme's glowing pattern. */
private val DarkBase = Color(0xFF0B0D10)

private object GradientCache {
    private val images = HashMap<String, ImageBitmap>()

    /** The gradient rendered small (48 × 64 px), scaled up smoothly when drawn. */
    fun image(key: String, colors: List<Long>): ImageBitmap = synchronized(images) {
        images.getOrPut(key) {
            val width = 48
            val height = 64
            val pixels = IntArray(width * height)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    pixels[y * width + x] = ThemeGradient.mix(colors, (x + 0.5f) / width, (y + 0.5f) / height)
                }
            }
            android.graphics.Bitmap.createBitmap(pixels, width, height, android.graphics.Bitmap.Config.ARGB_8888).asImageBitmap()
        }
    }
}

/** One doodle of the pattern: which glyph, where its centre is, how big and how turned. */
internal data class Doodle(val glyph: Int, val x: Float, val y: Float, val size: Float, val rotation: Float)

/**
 * The pattern's layout for a [width] × [height] area (in dp units scaled by [scale]): a jittered grid of 62 dp cells,
 * glyphs 22–30 dp, turned −25…25°, from a generator seeded with the theme id, so it never moves between launches.
 */
internal fun doodles(themeId: String, glyphCount: Int, width: Float, height: Float, density: Float, scale: Float = 1f): List<Doodle> {
    if (glyphCount == 0 || width <= 0f || height <= 0f) return emptyList()
    val random = Random(themeId.hashCode().toLong())
    val cell = 62f * density * scale
    val jitter = 12f * density * scale
    val columns = (width / cell).toInt() + 2
    val rows = (height / cell).toInt() + 2
    val result = ArrayList<Doodle>(columns * rows)
    for (row in 0 until rows) {
        for (column in 0 until columns) {
            // Every other row shifts half a cell, so the glyphs do not line up in columns.
            val offset = if (row % 2 == 1) cell / 2f else 0f
            val x = column * cell + offset + (random.nextFloat() * 2f - 1f) * jitter
            val y = row * cell + (random.nextFloat() * 2f - 1f) * jitter
            val size = (22f + random.nextFloat() * 8f) * density * scale
            val rotation = random.nextFloat() * 50f - 25f
            result += Doodle(random.nextInt(glyphCount), x, y, size, rotation)
        }
    }
    return result
}

private fun DrawScope.drawDoodles(items: List<Doodle>, painters: List<VectorPainter>, alpha: Float, filter: ColorFilter) {
    for (item in items) {
        val painter = painters[item.glyph]
        translate(item.x - item.size / 2f, item.y - item.size / 2f) {
            rotate(item.rotation, pivot = Offset(item.size / 2f, item.size / 2f)) {
                with(painter) { draw(Size(item.size, item.size), alpha = alpha, colorFilter = filter) }
            }
        }
    }
}

/**
 * A session background: the theme's gradient and doodles (light: dark doodles on the gradient; dark: the gradient
 * glowing through the doodles over near-black), the chosen photo (blurred when asked, dimmed in dark mode), or the plain
 * Crok Day / Night colour. [patternScale] shrinks the doodles for the theme cards.
 */
@Composable
fun SessionBackground(
    appearance: SessionAppearance,
    modifier: Modifier = Modifier,
    dark: Boolean = CrokTheme.colors.isDark,
    patternScale: Float = 1f,
) {
    val theme = appearance.theme
    val variant = theme.variant(dark)
    val photo = appearance.photo
    when {
        theme.id == SessionThemes.PHOTO && photo != null -> Box(modifier.clipToBounds()) {
            val blurred = appearance.blur
            val renderEffects = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            // No RenderEffect before Android 12: a tiny copy scaled up smoothly blurs nearly as well.
            val picture = if (blurred && !renderEffects) remember(photo) { photo.shrunk(24) } else photo
            Image(
                picture,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                filterQuality = FilterQuality.High,
                modifier = Modifier
                    .fillMaxSize()
                    .then(if (blurred && renderEffects) Modifier.blur(24.dp * patternScale) else Modifier),
            )
            if (dark) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.40f)))
        }
        variant == null -> Box(modifier.background(if (dark) CrokDark.screen else CrokLight.screen))
        else -> {
            val gradient = GradientCache.image("${theme.id}:$dark", variant.gradient)
            val painters = theme.glyphs.map { rememberVectorPainter(it) }
            Box(modifier.clipToBounds()) {
                // The gradient (dark: faint, over near-black).
                Canvas(Modifier.fillMaxSize().graphicsLayer()) {
                    if (dark) drawRect(DarkBase)
                    drawImage(
                        gradient,
                        dstSize = IntSize(size.width.toInt(), size.height.toInt()),
                        alpha = if (dark) 0.18f else 1f,
                        filterQuality = FilterQuality.High,
                    )
                }
                // The doodles, on their own layer so scrolling above never redraws them.
                Canvas(Modifier.fillMaxSize().graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)) {
                    val items = doodles(theme.id, painters.size, size.width, size.height, density, patternScale)
                    if (dark) {
                        drawDoodles(items, painters, 1f, ColorFilter.tint(Color.White))
                        // The gradient shows only where the doodles are.
                        drawImage(
                            gradient,
                            dstSize = IntSize(size.width.toInt(), size.height.toInt()),
                            alpha = 0.55f,
                            blendMode = BlendMode.SrcIn,
                            filterQuality = FilterQuality.High,
                        )
                    } else {
                        drawDoodles(items, painters, 0.12f, ColorFilter.tint(Color.Black))
                    }
                }
            }
        }
    }
}
