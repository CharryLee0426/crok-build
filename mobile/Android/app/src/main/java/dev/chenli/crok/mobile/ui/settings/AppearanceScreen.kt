package dev.chenli.crok.mobile.ui.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BlurOn
import androidx.compose.material.icons.outlined.Photo
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.Section
import dev.chenli.crok.mobile.ui.common.SectionRow
import dev.chenli.crok.mobile.ui.common.SettingsIcon
import dev.chenli.crok.mobile.ui.common.glassBarColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.SessionAppearance
import dev.chenli.crok.mobile.ui.theme.SessionBackground
import dev.chenli.crok.mobile.ui.theme.SessionTheme
import dev.chenli.crok.mobile.ui.theme.SessionThemeSpec
import dev.chenli.crok.mobile.ui.theme.SessionThemes

/** Profile › Appearance (mobile/DESIGN.md "Appearance"). */
data class AppearanceUiState(
    val mode: ThemeMode = ThemeMode.System,
    val appearance: SessionAppearance = SessionAppearance(),
)

data class AppearanceActions(
    val onBack: () -> Unit = {},
    val onMode: (ThemeMode) -> Unit = {},
    val onTheme: (String) -> Unit = {},
    val onBlur: (Boolean) -> Unit = {},
    val onPickPhoto: () -> Unit = {},
)

@Composable
fun AppearanceScreen(state: AppearanceUiState, actions: AppearanceActions, onPhoto: (android.net.Uri) -> Unit) {
    // The system photo picker: no permission prompt, one picture.
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let(onPhoto) }
    AppearanceContent(
        state,
        actions.copy(onPickPhoto = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }),
    )
}

@Composable
fun AppearanceContent(state: AppearanceUiState, actions: AppearanceActions) {
    val colors = CrokTheme.colors
    val appearance = state.appearance
    val selected = appearance.theme
    GlassScaffold(
        background = colors.grouped,
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = actions.onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                },
                title = { Text(stringResource(R.string.settings_appearance)) },
                colors = glassBarColors(),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 24.dp),
        ) {
            ThemePreview(appearance, Modifier.padding(horizontal = 16.dp).padding(top = 8.dp))

            Section(header = stringResource(R.string.appearance_session_theme)) {
                val cards = SessionThemes.cards(hasPhoto = appearance.photo != null)
                // Opens with the selected card in sight (one card of the ones before it showing).
                val strip = rememberLazyListState(initialFirstVisibleItemIndex = (cards.indexOfFirst { it.id == selected.id } - 1).coerceAtLeast(0))
                LazyRow(
                    state = strip,
                    modifier = Modifier.fillMaxWidth().testTag("theme-strip"),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(cards, key = { it.id }) { theme ->
                        ThemeCard(theme, appearance, selected = theme.id == selected.id, onClick = { actions.onTheme(theme.id) })
                    }
                }
                Text(
                    stringResource(selected.name),
                    color = colors.textSecondary,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(start = 16.dp, bottom = 12.dp),
                )
            }

            Section {
                SectionRow(
                    stringResource(R.string.appearance_choose_photo),
                    leading = { SettingsIcon(Icons.Outlined.Photo, Color(0xFF34C759)) },
                    divider = selected.id == SessionThemes.PHOTO,
                    onClick = actions.onPickPhoto,
                    modifier = Modifier.testTag("choose-photo"),
                ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
                if (selected.id == SessionThemes.PHOTO) {
                    SectionRow(
                        stringResource(R.string.appearance_blur),
                        leading = { SettingsIcon(Icons.Outlined.BlurOn, Color(0xFF5AC8FA)) },
                        onClick = { actions.onBlur(!appearance.blur) },
                    ) {
                        Switch(
                            checked = appearance.blur,
                            onCheckedChange = actions.onBlur,
                            colors = SwitchDefaults.colors(checkedTrackColor = colors.accent, checkedThumbColor = colors.onAccent),
                        )
                    }
                }
            }

            Section(header = stringResource(R.string.appearance_color_mode)) {
                Row(Modifier.padding(16.dp)) {
                    val options = listOf(
                        ThemeMode.System to R.string.theme_system,
                        ThemeMode.Light to R.string.theme_light,
                        ThemeMode.Dark to R.string.theme_dark,
                    )
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        options.forEachIndexed { index, (mode, label) ->
                            SegmentedButton(
                                selected = state.mode == mode,
                                onClick = { actions.onMode(mode) },
                                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                                colors = SegmentedButtonDefaults.colors(
                                    activeContainerColor = colors.bubbleOut,
                                    activeContentColor = colors.textPrimary,
                                    inactiveContainerColor = colors.card,
                                    inactiveContentColor = colors.textSecondary,
                                    activeBorderColor = colors.divider,
                                    inactiveBorderColor = colors.divider,
                                ),
                            ) { Text(stringResource(label)) }
                        }
                    }
                }
            }
        }
    }
}

/** Telegram's Appearance preview: the session background with an agent bubble and the person's reply. */
@Composable
private fun ThemePreview(appearance: SessionAppearance, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    val session = SessionTheme.colors(appearance, colors)
    Box(
        modifier
            .fillMaxWidth()
            .height(190.dp)
            .clip(RoundedCornerShape(16.dp))
            .testTag("theme-preview"),
    ) {
        SessionBackground(appearance, Modifier.fillMaxSize())
        Column(Modifier.fillMaxSize().padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)) {
            Text(
                stringResource(R.string.appearance_preview_in),
                color = colors.textPrimary,
                fontSize = 15.sp,
                modifier = Modifier
                    .fillMaxWidth(0.78f)
                    .clip(RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomEnd = 18.dp, bottomStart = 6.dp))
                    .background(colors.bubbleIn)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Row(
                    Modifier
                        .clip(RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomStart = 18.dp, bottomEnd = 6.dp))
                        .background(session.bubbleOut)
                        .padding(start = 12.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    Text(stringResource(R.string.appearance_preview_out), color = session.onBubbleOut, fontSize = 15.sp)
                    Spacer(Modifier.width(8.dp))
                    Text("15:42", color = session.outMeta, fontSize = 12.sp)
                    Spacer(Modifier.width(3.dp))
                    Icon(CrokIcons.DoneAll, contentDescription = null, tint = session.outTick, modifier = Modifier.size(15.dp))
                }
            }
        }
    }
}

/**
 * A theme card (about 84 × 116, rounded 12): the background with an incoming and an outgoing mini bubble and the
 * theme's emoji; the selected one has an accent ring outside a gap.
 */
@Composable
private fun ThemeCard(theme: SessionThemeSpec, current: SessionAppearance, selected: Boolean, onClick: () -> Unit) {
    val colors = CrokTheme.colors
    val appearance = current.copy(themeId = theme.id)
    val session = SessionTheme.colors(appearance, colors)
    val name = stringResource(theme.name)
    val shape = RoundedCornerShape(16.dp)
    Box(
        Modifier
            .size(width = 84.dp + 8.dp, height = 116.dp + 8.dp)
            .then(if (selected) Modifier.border(2.dp, colors.accent, shape) else Modifier)
            .padding(4.dp)
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = name
                this.selected = selected
            }
            .testTag("theme-${theme.id}"),
    ) {
        SessionBackground(appearance, Modifier.fillMaxSize(), patternScale = 0.45f)
        Column(Modifier.fillMaxSize().padding(8.dp)) {
            MiniBubble(colors.bubbleIn, 44.dp, Alignment.Start)
            Spacer(Modifier.height(5.dp))
            MiniBubble(session.bubbleOut, 38.dp, Alignment.End)
            Spacer(Modifier.weight(1f))
            Text(
                theme.emoji,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = if (theme.id == SessionThemes.NONE) colors.textSecondary else Color.Unspecified,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )
        }
    }
}

@Composable
private fun MiniBubble(color: Color, width: Dp, alignment: Alignment.Horizontal) {
    Box(Modifier.fillMaxWidth(), contentAlignment = if (alignment == Alignment.End) Alignment.CenterEnd else Alignment.CenterStart) {
        Box(Modifier.size(width = width, height = 14.dp).clip(RoundedCornerShape(7.dp)).background(color))
    }
}
