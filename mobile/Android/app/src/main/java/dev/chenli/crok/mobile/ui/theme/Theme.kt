package dev.chenli.crok.mobile.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.data.ThemeMode

/**
 * Crok's semantic colour tokens (Telegram's Theme.java keys, iOS PresentationTheme): every screen asks for a role, not
 * a hex value. Light is Crok Day's neutrals, dark is Crok Night's, both with Telegram's blue accent (relay/DESIGN.md §5,
 * "Look"): links, buttons, switches, selection, unread badges, the Menu pill and ticks. Online dots stay green.
 */
@Immutable
data class CrokColors(
    val isDark: Boolean,
    val accent: Color,
    val onAccent: Color,
    val screen: Color,
    val grouped: Color,
    val card: Color,
    val bar: Color,
    val sheet: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val divider: Color,
    /** The person's own prompt bubbles, and the text on them. */
    val bubbleOut: Color,
    val onBubbleOut: Color,
    val bubbleIn: Color,
    val online: Color,
    val warning: Color,
    val warningContainer: Color,
    val danger: Color,
    val dangerContainer: Color,
    val success: Color,
    val badgeMuted: Color,
    val codeBackground: Color,
    val inlineCode: Color,
    val link: Color,
    val swipePin: Color,
    val swipeArchive: Color,
    /** Liquid Glass bars and controls: the tint over the blurred content, and the rim of the glass. */
    val glassTint: Color,
    val glassRim: Color,
    val avatars: List<Color>,
    /** Code highlighting (relay/DESIGN.md §5 "Replies in Markdown", GitHub's colours). */
    val syntax: SyntaxColors,
)

@Immutable
data class SyntaxColors(
    val comment: Color,
    val keyword: Color,
    val string: Color,
    val number: Color,
    val function: Color,
    val type: Color,
    val tag: Color,
    val inserted: Color,
    val insertedBackground: Color,
    val deleted: Color,
    val deletedBackground: Color,
)

val SyntaxLight = SyntaxColors(
    comment = Color(0xFF6E7781),
    keyword = Color(0xFFCF222E),
    string = Color(0xFF0A3069),
    number = Color(0xFF0550AE),
    function = Color(0xFF8250DF),
    type = Color(0xFF953800),
    tag = Color(0xFF116329),
    inserted = Color(0xFF116329),
    insertedBackground = Color(0xFFDAFBE1),
    deleted = Color(0xFF82071E),
    deletedBackground = Color(0xFFFFEBE9),
)

val SyntaxDark = SyntaxColors(
    comment = Color(0xFF8B949E),
    keyword = Color(0xFFFF7B72),
    string = Color(0xFFA5D6FF),
    number = Color(0xFF79C0FF),
    function = Color(0xFFD2A8FF),
    type = Color(0xFFFFA657),
    tag = Color(0xFF7EE787),
    inserted = Color(0xFFAFF5B4),
    insertedBackground = Color(0xFF033A16),
    deleted = Color(0xFFFFDCD7),
    deletedBackground = Color(0xFF67060C),
)

private val AvatarPalette = listOf(
    Color(0xFF5B8A6A), // sage
    Color(0xFF3E8A92), // teal
    Color(0xFF3D7FD6), // blue
    Color(0xFF7E5BB5), // violet
    Color(0xFFB5587A), // rose
    Color(0xFFB5813A), // amber
    Color(0xFF5E6B7A), // slate
)

val CrokLight = CrokColors(
    isDark = false,
    accent = Color(0xFF3390EC),
    onAccent = Color(0xFFFFFFFF),
    screen = Color(0xFFF5F5F5),
    grouped = Color(0xFFEEEEEE),
    card = Color(0xFFFAFAFA),
    bar = Color(0xFFF5F5F5),
    sheet = Color(0xFFF7F7F7),
    textPrimary = Color(0xFF262626),
    textSecondary = Color(0xFF626262),
    textTertiary = Color(0xFF8A8A8A),
    divider = Color(0xFFD9D9DE),
    bubbleOut = Color(0xFFE1EFFD),
    onBubbleOut = Color(0xFF262626),
    bubbleIn = Color(0xFFFFFFFF),
    online = Color(0xFF3B9F55),
    warning = Color(0xFFB45F00),
    warningContainer = Color(0xFFFBE7CF),
    danger = Color(0xFFB3261E),
    dangerContainer = Color(0xFFF9DEDC),
    success = Color(0xFF3B7751),
    badgeMuted = Color(0xFF9E9E9E),
    codeBackground = Color(0xFFEAEAEA),
    inlineCode = Color(0xFFE3E3E3),
    link = Color(0xFF3390EC),
    swipePin = Color(0xFF3390EC),
    swipeArchive = Color(0xFF8E8E93),
    glassTint = Color(0xFFFAFAFA),
    glassRim = Color(0xFFFFFFFF),
    avatars = AvatarPalette,
    syntax = SyntaxLight,
)

val CrokDark = CrokColors(
    isDark = true,
    accent = Color(0xFF3E88F7),
    onAccent = Color(0xFFFFFFFF),
    screen = Color(0xFF141414),
    grouped = Color(0xFF0F0F0F),
    card = Color(0xFF1C1C1C),
    bar = Color(0xFF181818),
    sheet = Color(0xFF1E1E1E),
    textPrimary = Color(0xFFE1E1E1),
    textSecondary = Color(0xFF9A9A9A),
    textTertiary = Color(0xFF737373),
    divider = Color(0xFF2C2C30),
    bubbleOut = Color(0xFF2B5278),
    onBubbleOut = Color(0xFFFFFFFF),
    bubbleIn = Color(0xFF222222),
    online = Color(0xFF5FC77A),
    warning = Color(0xFFF0A94B),
    warningContainer = Color(0xFF3D2A12),
    danger = Color(0xFFF2877E),
    dangerContainer = Color(0xFF3D1C1A),
    success = Color(0xFF91C5A1),
    badgeMuted = Color(0xFF5A5A5A),
    codeBackground = Color(0xFF1C1C1C),
    inlineCode = Color(0xFF2A2A2A),
    link = Color(0xFF3E88F7),
    swipePin = Color(0xFF3E88F7),
    swipeArchive = Color(0xFF55555A),
    glassTint = Color(0xFF242426),
    glassRim = Color(0xFFFFFFFF),
    avatars = AvatarPalette,
    syntax = SyntaxDark,
)

private fun CrokColors.toMaterial(): ColorScheme {
    val base = if (isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = accent,
        onPrimary = onAccent,
        primaryContainer = bubbleOut,
        onPrimaryContainer = onBubbleOut,
        secondary = accent,
        onSecondary = onAccent,
        secondaryContainer = bubbleOut,
        onSecondaryContainer = onBubbleOut,
        tertiary = accent,
        background = screen,
        onBackground = textPrimary,
        surface = screen,
        onSurface = textPrimary,
        surfaceVariant = card,
        onSurfaceVariant = textSecondary,
        surfaceTint = Color.Transparent,
        surfaceContainerLowest = screen,
        surfaceContainerLow = card,
        surfaceContainer = bar,
        surfaceContainerHigh = sheet,
        surfaceContainerHighest = card,
        surfaceBright = card,
        surfaceDim = grouped,
        inverseSurface = textPrimary,
        inverseOnSurface = screen,
        inversePrimary = if (isDark) Color(0xFF3390EC) else Color(0xFF3E88F7),
        outline = textTertiary,
        outlineVariant = divider,
        error = danger,
        onError = if (isDark) Color(0xFF3D1C1A) else Color.White,
        errorContainer = dangerContainer,
        onErrorContainer = danger,
        scrim = Color.Black,
    )
}

private val LocalCrokColors = staticCompositionLocalOf { CrokLight }

/** Monospace for code, tool output and user codes. */
val Mono: FontFamily = FontFamily.Monospace

private val CrokTypography = Typography().let { t ->
    t.copy(
        titleLarge = t.titleLarge.copy(fontWeight = FontWeight.SemiBold, fontSize = 20.sp),
        titleMedium = t.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        bodyLarge = t.bodyLarge.copy(fontSize = 16.sp, lineHeight = 22.sp),
        bodyMedium = t.bodyMedium.copy(fontSize = 15.sp, lineHeight = 21.sp),
    )
}

object CrokTheme {
    val colors: CrokColors
        @Composable @ReadOnlyComposable get() = LocalCrokColors.current

    val codeStyle: TextStyle
        @Composable @ReadOnlyComposable get() = TextStyle(fontFamily = Mono, fontSize = 13.sp, lineHeight = 18.sp)
}

@Composable
fun isDarkFor(mode: ThemeMode): Boolean = when (mode) {
    ThemeMode.System -> isSystemInDarkTheme()
    ThemeMode.Light -> false
    ThemeMode.Dark -> true
}

/** The app's theme: Crok's own palette, never dynamic colour. */
@Composable
fun CrokTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors = if (dark) CrokDark else CrokLight
    CompositionLocalProvider(LocalCrokColors provides colors) {
        MaterialTheme(colorScheme = colors.toMaterial(), typography = CrokTypography, content = content)
    }
}
