package dev.chenli.crok.mobile.ui.o11y

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.Insights
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.O11yPage
import dev.chenli.crok.mobile.data.O11yPageState
import dev.chenli.crok.mobile.data.O11yRangeStore
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.logic.O11yLanguage
import dev.chenli.crok.mobile.logic.O11yLayout
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.connectionText
import dev.chenli.crok.mobile.ui.common.glassBarColors
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.time.ZoneId
import kotlinx.coroutines.launch

/** The o11y tab (mobile/DESIGN.md "o11y", dev builds): the page `home`, and the pages its rows open, on its own stack. */
@Composable
fun O11yTab(engine: CrokEngine, ranges: O11yRangeStore) {
    var stack by rememberSaveable { mutableStateOf(listOf(HOME)) }
    val lang = O11yLanguage.code(LocalConfiguration.current.locales[0]?.toLanguageTag())
    BackHandler(enabled = stack.size > 1) { stack = stack.dropLast(1) }
    AnimatedContent(
        targetState = stack,
        transitionSpec = {
            val forward = targetState.size > initialState.size
            val enter = slideInHorizontally { width -> if (forward) width else -width / 4 } + fadeIn()
            val exit = slideOutHorizontally { width -> if (forward) -width / 4 else width } + fadeOut()
            enter togetherWith exit
        },
        contentKey = { it.size to it.last() },
        label = "o11y-stack",
    ) { pages ->
        val id = pages.last()
        val viewModel = viewModel(key = "o11y-$id-$lang") { O11yPageViewModel(engine, id, lang, ranges) }
        O11yScreen(
            viewModel,
            onBack = if (pages.size > 1) ({ stack = stack.dropLast(1) }) else null,
            onOpen = { page -> stack = stack + page },
        )
    }
}

const val HOME = "home"

@Composable
fun O11yScreen(viewModel: O11yPageViewModel, onBack: (() -> Unit)?, onOpen: (String) -> Unit) {
    val ui by viewModel.state.collectAsStateWithLifecycle()
    val pulling by viewModel.pulling.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    O11yContent(
        pageId = viewModel.pageId,
        ui = ui,
        actions = O11yActions(
            onBack = onBack,
            onOpen = onOpen,
            onOpenUrl = { url -> runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) } },
            onRange = viewModel::select,
            onRefresh = viewModel::pullToRefresh,
            onCopy = { text -> scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("crok", text))) } },
            pulling = pulling,
        ),
    )
}

data class O11yActions(
    val onBack: (() -> Unit)? = null,
    val onOpen: (String) -> Unit = {},
    val onOpenUrl: (String) -> Unit = {},
    val onRange: (String) -> Unit = {},
    val onRefresh: () -> Unit = {},
    val onCopy: (String) -> Unit = {},
    /** Pull to refresh is waiting for the relay. */
    val pulling: Boolean = false,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun O11yContent(pageId: String, ui: O11yUi, actions: O11yActions) {
    val colors = CrokTheme.colors
    val page = ui.page
    GlassScaffold(
        background = colors.grouped,
        topBar = {
            TopAppBar(
                navigationIcon = {
                    actions.onBack?.let { back ->
                        IconButton(onClick = back) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                    }
                },
                title = { O11yTitle(pageId, ui) },
                actions = {
                    page?.url?.let { url ->
                        IconButton(onClick = { actions.onOpenUrl(url) }, modifier = Modifier.testTag("o11y-open-in-grafana")) {
                            Icon(Icons.Outlined.OpenInBrowser, contentDescription = stringResource(R.string.o11y_open_in_grafana))
                        }
                    }
                },
                colors = glassBarColors(),
            )
        },
    ) { padding ->
        val state = ui.state
        when {
            page != null -> O11yPageBody(page, ui, actions, padding)
            state != null && state.state != O11yPageState.State.OK -> O11yEmptyState(
                if (state.state == O11yPageState.State.FORBIDDEN) stringResource(R.string.o11y_not_available_title)
                else stringResource(R.string.o11y_not_set_up_title),
                if (state.state == O11yPageState.State.FORBIDDEN) stringResource(R.string.o11y_not_available_body)
                else stringResource(R.string.o11y_not_set_up_body),
                padding,
            )
            state == null && ui.error != null -> if (ui.missing) {
                O11yEmptyState(stringResource(R.string.o11y_not_set_up_title), stringResource(R.string.o11y_not_served), padding)
            } else {
                O11yEmptyState(stringResource(R.string.o11y_couldnt_update), ui.error, padding)
            }
            state?.error != null && !ui.refreshing -> O11yEmptyState(stringResource(R.string.o11y_couldnt_update), state.error, padding)
            else -> Column(
                Modifier.fillMaxSize().padding(padding).testTag("o11y-loading"),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp, color = colors.accent)
                Spacer(Modifier.size(12.dp))
                Text(stringResource(R.string.o11y_loading), fontSize = 15.sp, color = colors.textSecondary)
            }
        }
    }
}

/** The page's title over "LLM Observability · Updated 2 min ago" (or the connection state while not live). */
@Composable
private fun O11yTitle(pageId: String, ui: O11yUi) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    val page = ui.page
    Column(Modifier.testTag("o11y-title")) {
        Text(
            page?.title ?: if (pageId == HOME) stringResource(R.string.tab_o11y) else "",
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
        )
        if (ui.connection != ConnectionState.Connected) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
                Spacer(Modifier.width(6.dp))
                Text(connectionText(ui.connection), fontSize = 13.sp, color = colors.textSecondary, maxLines = 1)
            }
        } else if (page != null) {
            val ago = formatter.ago(RelativeTime.ago(page.builtAt.toLong(), ui.now.coerceAtLeast(page.builtAt.toLong()), ZoneId.systemDefault()))
            val updated = stringResource(R.string.o11y_updated, ago)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    listOfNotNull(page.subtitle?.takeIf { it.isNotEmpty() }, updated).joinToString(" · "),
                    fontSize = 13.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (ui.refreshing) {
                    Spacer(Modifier.width(6.dp))
                    CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun O11yEmptyState(title: String, message: String, padding: PaddingValues) {
    val colors = CrokTheme.colors
    Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 520.dp).padding(32.dp).testTag("o11y-empty"),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Outlined.Insights, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(56.dp))
            Text(title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary, textAlign = TextAlign.Center)
            Text(message, fontSize = 15.sp, color = colors.textSecondary, textAlign = TextAlign.Center)
        }
    }
}

/** The page itself: the range control, a banner when the last update failed, then the sections. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun O11yPageBody(page: O11yPage, ui: O11yUi, actions: O11yActions, padding: PaddingValues) {
    val shortScreen = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.height.toDp() } < 500.dp
    val pull = rememberPullToRefreshState()
    PullToRefreshBox(
        isRefreshing = actions.pulling,
        onRefresh = actions.onRefresh,
        state = pull,
        modifier = Modifier.fillMaxSize(),
        indicator = {
            PullToRefreshDefaults.Indicator(
                state = pull,
                isRefreshing = actions.pulling,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = padding.calculateTopPadding()),
            )
        },
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth.value >= O11yLayout.WIDE_DP
            val chartHeight = if (shortScreen) 180.dp else 200.dp
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
                    .padding(
                        top = padding.calculateTopPadding() + 8.dp,
                        bottom = padding.calculateBottomPadding() + 28.dp,
                        start = 16.dp,
                        end = 16.dp,
                    )
                    .testTag("o11y-page-${page.id}"),
                verticalArrangement = Arrangement.spacedBy(22.dp),
            ) {
                if (page.ranges.size > 1) RangeRow(page, actions.onRange)
                ui.state?.error?.let { ErrorBanner(it) }
                O11yLayout.rows(page.sections, wide).forEach { row ->
                    when (row) {
                        is O11yLayout.Row.Single ->
                            O11ySectionView(row.section, wide, chartHeight, ui.now, actions.onOpen, actions.onCopy)
                        is O11yLayout.Row.Pair -> Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            O11ySectionView(row.first, wide, chartHeight, ui.now, actions.onOpen, actions.onCopy, Modifier.weight(1f))
                            O11ySectionView(row.second, wide, chartHeight, ui.now, actions.onOpen, actions.onCopy, Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RangeRow(page: O11yPage, onRange: (String) -> Unit) {
    val label = stringResource(R.string.o11y_range)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().testTag("o11y-range").semantics { contentDescription = label }) {
        page.ranges.forEachIndexed { index, range ->
            SegmentedButton(
                selected = range == page.range,
                onClick = { onRange(range) },
                shape = SegmentedButtonDefaults.itemShape(index, page.ranges.size),
                modifier = Modifier.testTag("o11y-range-$range"),
                icon = {},
            ) { Text(rangeLabel(range), maxLines = 1) }
        }
    }
}

/** "24h" → "24h" / "24小时" / "24 Std", "7d" → "7d" / "7天" / "7 T" (mobile/DESIGN.md Words). */
@Composable
fun rangeLabel(range: String): String {
    val n = range.dropLast(1).toIntOrNull() ?: return range
    return when (range.last()) {
        'h' -> stringResource(R.string.o11y_range_hours, n)
        'd' -> stringResource(R.string.o11y_range_days, n)
        else -> range
    }
}

@Composable
private fun ErrorBanner(error: String) {
    val colors = CrokTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(colors.card)
            .padding(12.dp)
            .testTag("o11y-error-banner"),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Error, contentDescription = null, tint = colors.danger, modifier = Modifier.size(20.dp))
        Column {
            Text(stringResource(R.string.o11y_couldnt_update), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            Text(error, fontSize = 13.sp, color = colors.textSecondary, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}
