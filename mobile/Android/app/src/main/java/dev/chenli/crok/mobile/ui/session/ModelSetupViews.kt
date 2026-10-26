package dev.chenli.crok.mobile.ui.session

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.EffortChoice
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.logic.ModelSetup
import dev.chenli.crok.mobile.logic.SetupPill
import dev.chenli.crok.mobile.logic.SetupRow
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassMenu
import dev.chenli.crok.mobile.ui.common.GlassMenuRow
import dev.chenli.crok.mobile.ui.common.GlassShapes
import dev.chenli.crok.mobile.ui.common.glass
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlin.math.roundToInt

/**
 * Which of the setup row's pickers is open (Choose a Model, the thinking menu), shared by the session screen and its
 * info sheet, whose Model and Thinking level rows open the same ones. The initial values are for screenshots.
 */
@Stable
class SetupPickers(modelSheet: Boolean = false, thinkingMenu: Boolean = false, query: String = "") {
    var modelSheet by mutableStateOf(modelSheet)
    var thinkingMenu by mutableStateOf(thinkingMenu)

    /** Choose a Model's search text. */
    var query by mutableStateOf(query)

    /** Where the thinking pill is (its left edge in the window, px): its menu opens above it. */
    var thinkingLeft by mutableStateOf<Float?>(null)

    fun openModelSheet() {
        query = ""
        thinkingMenu = false
        modelSheet = true
    }

    fun openThinkingMenu() {
        modelSheet = false
        thinkingMenu = true
    }
}

@Composable
fun rememberSetupPickers(): SetupPickers = remember { SetupPickers() }

/**
 * The setup row above the composer's field (mobile/DESIGN.md "Model and thinking level"): the model pill (a chip glyph,
 * the model's name truncated in the middle, a chevron) and, when the model has levels, the thinking pill (a brain
 * glyph). Glass capsules like the composer's field, not accent-filled: the Menu pill is the accent one.
 */
@Composable
fun SetupRowView(row: SetupRow, onModel: () -> Unit, onThinking: () -> Unit, onThinkingPlaced: (Float) -> Unit) {
    val default = stringResource(R.string.setup_default)
    BoxWithConstraints(Modifier.fillMaxWidth().padding(bottom = 8.dp).testTag("setup-row")) {
        // The model's name takes at most about 60 % of the row; the thinking pill gets what is left.
        val modelMax = maxWidth * 0.6f
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            SetupPillView(
                icon = Icons.Outlined.Memory,
                what = stringResource(R.string.info_model),
                label = row.model.label ?: default,
                pill = row.model,
                onClick = onModel,
                modifier = Modifier.widthIn(max = modelMax).testTag("setup-model"),
            )
            row.thinking?.let { thinking ->
                SetupPillView(
                    icon = Icons.Outlined.Psychology,
                    what = stringResource(R.string.info_effort),
                    label = thinking.label ?: default,
                    pill = thinking,
                    onClick = onThinking,
                    modifier = Modifier
                        .weight(1f, fill = false)
                        .onGloballyPositioned { onThinkingPlaced(it.boundsInRoot().left) }
                        .testTag("setup-thinking"),
                )
            }
        }
    }
}

@Composable
private fun SetupPillView(icon: ImageVector, what: String, label: String, pill: SetupPill, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    Row(
        modifier
            .height(30.dp)
            .glass(GlassShapes.capsule)
            .clip(GlassShapes.capsule)
            // Busy: the change is on its way, taps wait. Dimmed: still tappable, it says why there is no choice.
            .clickable(enabled = pill.enabled && !pill.busy, onClickLabel = what, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "$what, $label" }
            .padding(start = 10.dp, end = 8.dp)
            .alpha(if (pill.dimmed) 0.5f else 1f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(5.dp))
        Text(
            label,
            color = colors.textPrimary,
            style = MaterialTheme.typography.labelMedium,
            maxLines = 1,
            overflow = TextOverflow.MiddleEllipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        Spacer(Modifier.width(3.dp))
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            if (pill.busy) {
                CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
            } else {
                Icon(CrokIcons.ExpandMore, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
            }
        }
    }
}

/**
 * Choose a Model: a bottom sheet with a search field and the computer's models by provider (the id up to its first
 * `/`; ids without one under the computer's name), the current one checked. In a new session a first row, Default
 * (the computer's own choice); in a session a footer saying changes apply to the next message.
 */
@Composable
fun ModelSheet(
    models: List<ModelChoice>,
    selected: String?,
    newSession: Boolean,
    computer: String,
    query: String,
    onQuery: (String) -> Unit,
    onPick: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = CrokTheme.colors
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(),
        containerColor = colors.sheet,
    ) {
        ModelSheetContent(models, selected, newSession, computer, query, onQuery, onPick)
    }
}

@Composable
private fun ModelSheetContent(
    models: List<ModelChoice>,
    selected: String?,
    newSession: Boolean,
    computer: String,
    query: String,
    onQuery: (String) -> Unit,
    onPick: (String?) -> Unit,
) {
    val colors = CrokTheme.colors
    val sections = remember(models, query) { ModelSetup.sections(models, query) }
    val searching = query.isNotBlank()
    Column(Modifier.fillMaxWidth().fillMaxHeight().testTag("model-sheet")) {
        Text(
            stringResource(R.string.setup_choose_model),
            style = MaterialTheme.typography.titleMedium,
            color = colors.textPrimary,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 10.dp).semantics { heading() },
        )
        SheetSearchField(query, onQuery)
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(top = 6.dp, bottom = 16.dp)) {
            if (newSession && !searching) {
                item(key = "default", contentType = "row") {
                    ModelRow(
                        title = stringResource(R.string.setup_default),
                        subtitle = stringResource(R.string.setup_computer_choice, computer),
                        current = selected == null,
                        divider = false,
                        onClick = { onPick(null) },
                    )
                }
            }
            if (sections.isEmpty()) {
                item(key = "none", contentType = "none") {
                    Text(
                        stringResource(R.string.setup_no_results),
                        color = colors.textSecondary,
                        style = MaterialTheme.typography.bodyLarge,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 40.dp),
                    )
                }
            }
            sections.forEach { section ->
                item(key = "h:${section.provider}", contentType = "header") {
                    Text(
                        section.provider ?: computer,
                        style = MaterialTheme.typography.labelLarge,
                        color = colors.accent,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 4.dp).semantics { heading() },
                    )
                }
                val last = section.models.lastOrNull()
                items(section.models, key = { "m:${it.id}" }, contentType = { "row" }) { model ->
                    ModelRow(
                        title = model.label,
                        id = model.id.takeIf { it != model.name && model.name.isNotBlank() },
                        subtitle = model.description?.takeIf { it.isNotBlank() },
                        current = model.id == selected,
                        divider = model !== last,
                        onClick = { onPick(model.id) },
                    )
                }
            }
            if (!newSession && sections.isNotEmpty()) {
                item(key = "footer", contentType = "footer") {
                    Text(
                        stringResource(R.string.setup_next_message),
                        color = colors.textSecondary,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp),
                    )
                }
            }
        }
    }
}

/** The search field: the app's transparent field on a soft capsule, with a search glyph and a clear button. */
@Composable
private fun SheetSearchField(query: String, onQuery: (String) -> Unit) {
    val colors = CrokTheme.colors
    TextField(
        value = query,
        onValueChange = onQuery,
        placeholder = { Text(stringResource(R.string.setup_search), maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingIcon = { Icon(CrokIcons.Search, contentDescription = null, tint = colors.textSecondary) },
        trailingIcon = if (query.isEmpty()) {
            null
        } else {
            {
                IconButton(onClick = { onQuery("") }) {
                    Icon(CrokIcons.Close, contentDescription = stringResource(R.string.cd_clear), tint = colors.textSecondary)
                }
            }
        },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.Transparent,
            unfocusedContainerColor = Color.Transparent,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            cursorColor = colors.accent,
        ),
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(GlassShapes.rounded(14.dp))
            // A shade off the sheet: darker in light mode, lighter in dark mode.
            .background(colors.textPrimary.copy(alpha = if (colors.isDark) 0.08f else 0.06f))
            .testTag("model-search"),
    )
}

/** One choice: the name (semibold when current), the id when it differs (monospaced), the description; a checkmark. */
@Composable
private fun ModelRow(
    title: String,
    current: Boolean,
    divider: Boolean,
    onClick: () -> Unit,
    id: String? = null,
    subtitle: String? = null,
) {
    val colors = CrokTheme.colors
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = current },
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 20.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    color = colors.textPrimary,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (id != null) {
                    Text(
                        id,
                        color = colors.textSecondary,
                        style = CrokTheme.codeStyle.copy(fontSize = 12.sp, lineHeight = 16.sp),
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis,
                    )
                }
                if (subtitle != null) {
                    Text(subtitle, color = colors.textSecondary, fontSize = 13.sp, lineHeight = 17.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            if (current) {
                Spacer(Modifier.width(12.dp))
                Icon(CrokIcons.Check, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
            }
        }
        if (divider) HorizontalDivider(Modifier.padding(start = 20.dp), thickness = 0.5.dp, color = colors.divider)
    }
}

/**
 * The thinking menu: a glass popup above the composer, at the thinking pill, over a dimmed screen. The model's levels in
 * their order, by name with the description under it; in a new session Default first; a checkmark on the current one.
 * Put it in a [dev.chenli.crok.mobile.ui.common.GlassScaffold]'s `floating` slot so the glass reads the transcript.
 */
@Composable
fun BoxScope.ThinkingMenu(
    efforts: List<EffortChoice>,
    selected: String?,
    newSession: Boolean,
    anchorLeft: Float?,
    bottom: Dp,
    onPick: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = CrokTheme.colors
    BackHandler(onBack = onDismiss)
    Box(
        Modifier
            .matchParentSize()
            .background(Color.Black.copy(alpha = if (colors.isDark) 0.35f else 0.16f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
    )
    val check: @Composable () -> Unit = { Icon(CrokIcons.Check, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp)) }
    // At the pill's left edge, kept on screen; its bottom just above the composer.
    Layout(
        content = {
            // Narrow, like a pill's menu: it opens at the pill rather than across the screen.
            GlassMenu(Modifier.widthIn(max = 240.dp).testTag("thinking-menu")) {
                if (newSession) {
                    GlassMenuRow(
                        stringResource(R.string.setup_default),
                        modifier = Modifier.semantics { this.selected = selected == null },
                        trailing = if (selected == null) check else null,
                        onClick = { onPick(null) },
                    )
                }
                efforts.forEach { effort ->
                    GlassMenuRow(
                        effort.label,
                        modifier = Modifier.semantics { this.selected = effort.id == selected },
                        subtitle = effort.description?.takeIf { it.isNotBlank() },
                        trailing = if (effort.id == selected) check else null,
                        onClick = { onPick(effort.id) },
                    )
                }
            }
        },
        modifier = Modifier.matchParentSize().padding(bottom = bottom),
    ) { measurables, constraints ->
        val margin = 8.dp.roundToPx()
        val menu = measurables.single().measure(constraints.copy(minWidth = 0, minHeight = 0, maxWidth = (constraints.maxWidth - 2 * margin).coerceAtLeast(0)))
        layout(constraints.maxWidth, constraints.maxHeight) {
            val left = (anchorLeft?.roundToInt() ?: margin).coerceIn(margin, (constraints.maxWidth - menu.width - margin).coerceAtLeast(margin))
            menu.place(left, constraints.maxHeight - menu.height)
        }
    }
}
