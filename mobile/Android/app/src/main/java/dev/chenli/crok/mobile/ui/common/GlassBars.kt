package dev.chenli.crok.mobile.ui.common

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarColors
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.ui.theme.CrokTheme

/**
 * Room a floating bar below a screen takes (the home tab bar): the screen's own content leaves it free at the bottom so
 * its last rows can scroll up out from under the glass.
 */
val LocalBottomChrome = compositionLocalOf { 0.dp }

/** Top bar colours for a bar drawn on glass: the glass is the background. */
@Composable
fun glassBarColors(): TopAppBarColors = TopAppBarDefaults.topAppBarColors(
    containerColor = Color.Transparent,
    scrolledContainerColor = Color.Transparent,
)

/**
 * A screen whose bars are Liquid Glass over its content: the content fills the whole screen and gets the bars' heights
 * as padding (for a list's `contentPadding`, so rows scroll under the bars), the top bar sits on a glass panel, and
 * [floating] controls (round buttons) and the [bottomBar] read the same content through [LocalGlassBackdrop].
 */
@Composable
fun GlassScaffold(
    modifier: Modifier = Modifier,
    background: Color = CrokTheme.colors.screen,
    topBar: @Composable () -> Unit = {},
    bottomBar: @Composable () -> Unit = {},
    snackbarHost: @Composable () -> Unit = {},
    floating: @Composable BoxScope.(PaddingValues) -> Unit = {},
    /** Drawn under the content, inside what the glass reads (a session's background). */
    wallpaper: (@Composable () -> Unit)? = null,
    content: @Composable (PaddingValues) -> Unit,
) {
    val backdrop = rememberGlassBackdrop(background)
    val bottomChrome = LocalBottomChrome.current
    val direction = LocalLayoutDirection.current
    ProvideGlass(backdrop) {
        Scaffold(
            modifier = modifier,
            containerColor = background,
            contentWindowInsets = WindowInsets(0, 0, 0, 0),
            snackbarHost = snackbarHost,
            topBar = { Box(Modifier.fillMaxWidth().glass(GlassShapes.topPanel, GlassStyle.Bar)) { topBar() } },
            bottomBar = bottomBar,
        ) { bars ->
            val padding = PaddingValues(
                start = bars.calculateStartPadding(direction),
                top = bars.calculateTopPadding(),
                end = bars.calculateEndPadding(direction),
                bottom = bars.calculateBottomPadding() + bottomChrome,
            )
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxSize().glassContent(backdrop)) {
                    wallpaper?.invoke()
                    content(padding)
                }
                floating(padding)
            }
        }
    }
}

/**
 * One tab of [GlassTabBar]: an icon (or [customIcon], e.g. the account picture, told whether the tab is selected), a
 * [badge] count, and a [menu] that a long press opens above the bar (Telegram's tab context menus).
 */
data class GlassTab(
    val label: String,
    val icon: ImageVector? = null,
    val selectedIcon: ImageVector? = icon,
    val badge: Int = 0,
    val customIcon: (@Composable (selected: Boolean) -> Unit)? = null,
    val menu: (@Composable ColumnScope.(dismiss: () -> Unit) -> Unit)? = null,
    val tag: String? = null,
)

/**
 * What takes the tab bar's place while a screen inside asks for it (Edit mode's bottom toolbar, Telegram's): the screen
 * sets [replacement] and clears it when it leaves.
 */
class TabBarSlot {
    var replacement by mutableStateOf<(@Composable () -> Unit)?>(null)
}

val LocalTabBarSlot = compositionLocalOf<TabBarSlot?> { null }

/** Puts [bar] in the tab bar's place while [active]. */
@Composable
fun ReplaceTabBar(active: Boolean, bar: @Composable () -> Unit) {
    val slot = LocalTabBarSlot.current ?: return
    val latest by rememberUpdatedState(bar)
    DisposableEffect(slot, active) {
        val content: @Composable () -> Unit = { latest() }
        if (active) slot.replacement = content
        onDispose { if (slot.replacement === content) slot.replacement = null }
    }
}

/**
 * The home screen's tab bar as iOS 26 draws it: a floating glass capsule above the navigation bar, the selected tab on a
 * lighter capsule of its own. The content under it fills the whole screen; [LocalBottomChrome] tells it how much room
 * the bar takes. A long press on a tab with a menu opens it over a dimmed screen, on glass, above the bar.
 */
@Composable
fun GlassTabScaffold(
    tabs: List<GlassTab>,
    selected: Int,
    onSelect: (Int) -> Unit,
    initialMenu: Int? = null,
    content: @Composable () -> Unit,
) {
    val colors = CrokTheme.colors
    val density = LocalDensity.current
    val backdrop = rememberGlassBackdrop(colors.screen)
    var chrome by remember { mutableStateOf(0.dp) }
    var menuFor by remember { mutableStateOf(initialMenu) }
    val slot = remember { TabBarSlot() }
    Box(Modifier.fillMaxSize().background(colors.screen)) {
        Box(Modifier.fillMaxSize().glassContent(backdrop)) {
            CompositionLocalProvider(LocalBottomChrome provides chrome, LocalTabBarSlot provides slot) { content() }
        }
        val open = menuFor?.let { index -> tabs.getOrNull(index)?.menu?.let { index to it } }
        if (open != null) {
            val dismiss = { menuFor = null }
            BackHandler(onBack = dismiss)
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = if (colors.isDark) 0.35f else 0.16f))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = dismiss),
            )
            val (index, menu) = open
            val alignment = if (index < tabs.size / 2.0) Alignment.BottomStart else Alignment.BottomEnd
            Box(
                Modifier
                    .align(alignment)
                    .navigationBarsPadding()
                    .padding(bottom = chrome + 4.dp, start = 20.dp, end = 20.dp),
            ) {
                ProvideGlass(backdrop) { GlassMenu { menu(dismiss) } }
            }
        }
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 8.dp)
                .onSizeChanged { chrome = with(density) { it.height.toDp() } + 16.dp }
                .padding(horizontal = 24.dp),
        ) {
            ProvideGlass(backdrop) {
                val replacement = slot.replacement
                if (replacement != null) replacement() else GlassTabBar(tabs, selected, onSelect, onLongPress = { menuFor = it })
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GlassTabBar(tabs: List<GlassTab>, selected: Int, onSelect: (Int) -> Unit, onLongPress: (Int) -> Unit) {
    val colors = CrokTheme.colors
    Row(
        Modifier
            .glass(GlassShapes.capsule)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        tabs.forEachIndexed { index, tab ->
            val active = index == selected
            Column(
                Modifier
                    .width(96.dp)
                    .clip(GlassShapes.capsule)
                    .background(if (active) colors.accent.copy(alpha = if (colors.isDark) 0.22f else 0.12f) else Color.Transparent)
                    .combinedClickable(
                        role = Role.Tab,
                        onClick = { onSelect(index) },
                        onLongClick = if (tab.menu != null) ({ onLongPress(index) }) else null,
                    )
                    .semantics { this.selected = active }
                    .then(if (tab.tag != null) Modifier.testTag(tab.tag) else Modifier)
                    .padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val tint = if (active) colors.accent else colors.textSecondary
                Box {
                    Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) {
                        val custom = tab.customIcon
                        if (custom != null) {
                            custom(active)
                        } else {
                            (if (active) tab.selectedIcon else tab.icon)?.let {
                                Icon(it, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
                            }
                        }
                    }
                    if (tab.badge > 0) {
                        TabBadge(tab.badge, Modifier.align(Alignment.TopEnd).offset(x = 12.dp, y = (-4).dp))
                    }
                }
                Spacer(Modifier.height(2.dp))
                Text(tab.label, color = tint, fontSize = 11.sp, fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1)
            }
        }
    }
}

/** The accent count on a tab (Telegram's tab badge). */
@Composable
private fun TabBadge(count: Int, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    Box(
        modifier
            .heightIn(min = 18.dp)
            .widthIn(min = 18.dp)
            .clip(GlassShapes.capsule)
            .background(colors.accent)
            .padding(horizontal = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(if (count > 99) "99+" else count.toString(), color = colors.onAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

/** A menu card on glass (the tab menus, the computer switcher). */
@Composable
fun GlassMenu(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .widthIn(min = 230.dp, max = 320.dp)
            .glass(GlassShapes.rounded(20.dp), GlassStyle.Bar)
            .clip(GlassShapes.rounded(20.dp))
            .padding(vertical = 6.dp),
        content = content,
    )
}

/** One row of a [GlassMenu]: an optional leading glyph, the title (and a second line), and a trailing mark. */
@Composable
fun GlassMenuRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    subtitleColor: Color = CrokTheme.colors.textSecondary,
    titleColor: Color = CrokTheme.colors.textPrimary,
    enabled: Boolean = true,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: () -> Unit,
) {
    Row(
        modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .heightIn(min = 48.dp)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .alpha(if (enabled) 1f else 0.4f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = titleColor, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) Text(subtitle, color = subtitleColor, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (trailing != null) {
            Spacer(Modifier.width(10.dp))
            trailing()
        }
    }
}

/** A hairline between a [GlassMenu]'s groups. */
@Composable
fun GlassMenuDivider() {
    Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).height(0.5.dp).background(CrokTheme.colors.divider))
}

/**
 * A menu dropped over a screen (the Sessions title's computer switcher): a dimmed area that closes it, and the glass
 * card at [alignment] with [padding] around it. Put it in a [GlassScaffold]'s `floating` slot so the glass reads the
 * content beneath.
 */
@Composable
fun BoxScope.GlassMenuOverlay(
    onDismiss: () -> Unit,
    alignment: Alignment = Alignment.TopCenter,
    padding: PaddingValues = PaddingValues(),
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = CrokTheme.colors
    BackHandler(onBack = onDismiss)
    Box(
        Modifier
            .matchParentSize()
            .background(Color.Black.copy(alpha = if (colors.isDark) 0.35f else 0.16f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
    )
    Box(Modifier.align(alignment).padding(padding)) { GlassMenu(content = content) }
}
