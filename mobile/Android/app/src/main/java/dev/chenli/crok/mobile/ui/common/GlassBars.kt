package dev.chenli.crok.mobile.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.rememberScrollState
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
                Box(Modifier.fillMaxSize().glassContent(backdrop)) { content(padding) }
                floating(padding)
            }
        }
    }
}

/** One tab of [GlassTabBar]. */
data class GlassTab(val label: String, val icon: ImageVector, val selectedIcon: ImageVector = icon)

/**
 * The home screen's tab bar as iOS 26 draws it: a floating glass capsule above the navigation bar, the selected tab on a
 * lighter capsule of its own. The content under it fills the whole screen; [LocalBottomChrome] tells it how much room
 * the bar takes.
 */
@Composable
fun GlassTabScaffold(tabs: List<GlassTab>, selected: Int, onSelect: (Int) -> Unit, content: @Composable () -> Unit) {
    val colors = CrokTheme.colors
    val density = LocalDensity.current
    val backdrop = rememberGlassBackdrop(colors.screen)
    var chrome by remember { mutableStateOf(0.dp) }
    Box(Modifier.fillMaxSize().background(colors.screen)) {
        Box(Modifier.fillMaxSize().glassContent(backdrop)) {
            CompositionLocalProvider(LocalBottomChrome provides chrome) { content() }
        }
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 8.dp)
                .onSizeChanged { chrome = with(density) { it.height.toDp() } + 16.dp }
                .padding(horizontal = 24.dp),
        ) {
            ProvideGlass(backdrop) { GlassTabBar(tabs, selected, onSelect) }
        }
    }
}

@Composable
private fun GlassTabBar(tabs: List<GlassTab>, selected: Int, onSelect: (Int) -> Unit) {
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
                    .clickable(role = Role.Tab) { onSelect(index) }
                    .semantics { this.selected = active }
                    .padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val tint = if (active) colors.accent else colors.textSecondary
                Icon(if (active) tab.selectedIcon else tab.icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
                Spacer(Modifier.height(2.dp))
                Text(tab.label, color = tint, fontSize = 11.sp, fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1)
            }
        }
    }
}

/**
 * Folder tabs on a glass bar (Telegram's FilterTabsView, drawn as iOS 26 capsules): the selected one on a soft accent
 * capsule.
 */
@Composable
fun <T> GlassChipTabs(
    items: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = CrokTheme.colors
    Row(
        modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp)
            .padding(bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items.forEach { (value, label) ->
            val active = value == selected
            Box(
                Modifier
                    .heightIn(min = 34.dp)
                    .clip(GlassShapes.capsule)
                    .background(if (active) colors.accent.copy(alpha = if (colors.isDark) 0.24f else 0.13f) else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(value) }
                    .semantics { this.selected = active }
                    .padding(horizontal = 14.dp, vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    color = if (active) colors.accent else colors.textSecondary,
                    fontSize = 15.sp,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }
    }
}
