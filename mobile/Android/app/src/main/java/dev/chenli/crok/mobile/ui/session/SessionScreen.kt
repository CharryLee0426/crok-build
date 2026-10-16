package dev.chenli.crok.mobile.ui.session

import android.content.ClipData
import android.os.Build
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.logic.PlanSummary
import dev.chenli.crok.mobile.logic.TranscriptItem
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.WorkingDots
import dev.chenli.crok.mobile.ui.common.connectionText
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

data class SessionActions(
    val onBack: () -> Unit = {},
    val onInfo: () -> Unit = {},
    val onDraft: (String) -> Unit = {},
    val onSend: () -> Unit = {},
    val onStop: () -> Unit = {},
    val onLoadMore: () -> Unit = {},
    val onReload: () -> Unit = {},
    val transcript: TranscriptActions = TranscriptActions(),
)

@Composable
fun SessionScreen(viewModel: SessionViewModel, onBack: () -> Unit, infoSheet: @Composable (onDismiss: () -> Unit) -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val clipboard = LocalClipboard.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    var showInfo by rememberSaveable { mutableStateOf(false) }

    LifecycleResumeEffect(viewModel) {
        viewModel.setVisible(true)
        onPauseOrDispose { viewModel.setVisible(false) }
    }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is SessionEvent.StopFailed -> snackbar.showSnackbar(resources.getString(R.string.stop_failed, event.message))
            }
        }
    }

    SessionContent(
        state = state,
        draft = viewModel.draft,
        snackbar = snackbar,
        now = System.currentTimeMillis(),
        actions = SessionActions(
            onBack = onBack,
            onInfo = { showInfo = true },
            onDraft = viewModel::updateDraft,
            onSend = viewModel::send,
            onStop = viewModel::stop,
            onLoadMore = viewModel::loadMore,
            onReload = viewModel::reload,
            transcript = TranscriptActions(
                onCopy = { text ->
                    scope.launch {
                        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("crok", text)))
                        // Android 13+ confirms copies itself.
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) snackbar.showSnackbar(resources.getString(R.string.copied))
                    }
                },
                onRetry = viewModel::retry,
                onDelete = viewModel::discard,
            ),
        ),
    )
    if (showInfo) infoSheet { showInfo = false }
}

@Composable
fun SessionContent(
    state: SessionUiState,
    draft: String,
    now: Long,
    actions: SessionActions,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
    listState: LazyListState = rememberLazyListState(),
) {
    val colors = CrokTheme.colors
    val scope = rememberCoroutineScope()
    var planExpanded by rememberSaveable { mutableStateOf(false) }

    // Follow the newest item while the reader is at the bottom; count new ones while scrolled away.
    val newestKey = state.items.firstOrNull()?.key
    val atBottom by remember { derivedStateOf { listState.firstVisibleItemIndex <= 1 } }
    var seenNewest by remember { mutableStateOf(newestKey) }
    var newCount by remember { mutableIntStateOf(0) }
    LaunchedEffect(newestKey) {
        if (newestKey == null) return@LaunchedEffect
        if (listState.firstVisibleItemIndex <= 2) {
            listState.animateScrollToItem(0)
            seenNewest = newestKey
            newCount = 0
        } else {
            val seenIndex = state.items.indexOfFirst { it.key == seenNewest }.let { if (it < 0) state.items.size else it }
            newCount = state.items.take(seenIndex).count { it !is TranscriptItem.Day }
        }
    }
    LaunchedEffect(atBottom) {
        if (atBottom) {
            seenNewest = newestKey
            newCount = 0
        }
    }
    // Older pages load as the reader nears the top (the end of the reversed list).
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            info.totalItemsCount > 0 && last >= info.totalItemsCount - 8
        }.distinctUntilChanged().filter { it }.collect { actions.onLoadMore() }
    }

    Scaffold(
        containerColor = colors.screen,
        snackbarHost = { SnackbarHost(snackbar) },
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            Column(Modifier.background(colors.bar)) {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = actions.onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                    },
                    title = { SessionHeader(state) },
                    actions = {
                        IconButton(onClick = actions.onInfo) { Icon(CrokIcons.Info, contentDescription = stringResource(R.string.session_info)) }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.bar),
                )
                val summary = state.planSummary
                if (summary != null) {
                    PlanBar(summary, state.plan, planExpanded) { planExpanded = !planExpanded }
                } else {
                    HorizontalDivider(color = colors.divider, thickness = 0.5.dp)
                }
            }
        },
        bottomBar = { Composer(state, draft, actions) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.gone -> CenterNote(stringResource(R.string.session_gone))
                !state.loaded && state.error != null -> Column(
                    Modifier.align(Alignment.Center).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(stringResource(R.string.transcript_load_failed, state.error), color = colors.textSecondary, textAlign = TextAlign.Center)
                    TextButton(onClick = actions.onReload) { Text(stringResource(R.string.action_retry), color = colors.accent) }
                }
                !state.loaded -> CircularProgressIndicator(Modifier.align(Alignment.Center), color = colors.accent)
                state.historyOnComputer && state.deviceOnline -> Column(
                    Modifier.align(Alignment.Center).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp, color = colors.accent)
                    Spacer(Modifier.height(16.dp))
                    Text(
                        stringResource(R.string.session_history_loading, state.deviceName),
                        color = colors.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
                state.historyOnComputer -> Column(
                    Modifier.align(Alignment.Center).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(CrokIcons.Laptop, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(40.dp))
                    Spacer(Modifier.height(16.dp))
                    Text(
                        stringResource(R.string.session_history_offline, state.deviceName),
                        color = colors.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
                state.items.isEmpty() -> CenterNote(stringResource(R.string.transcript_empty))
                else -> LazyColumn(
                    state = listState,
                    reverseLayout = true,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(top = 8.dp, bottom = 12.dp),
                ) {
                    items(state.items, key = { it.key }, contentType = { it::class.simpleName }) { item ->
                        TranscriptRow(item, now, actions.transcript)
                    }
                    item(key = "history-edge", contentType = "edge") {
                        Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                            when {
                                state.loadingMore -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent)
                                state.historyComplete -> Text(
                                    stringResource(R.string.transcript_beginning),
                                    color = colors.textTertiary,
                                    style = MaterialTheme.typography.labelMedium,
                                )
                            }
                        }
                    }
                }
            }
            AnimatedVisibility(
                visible = !atBottom && state.items.isNotEmpty(),
                enter = scaleIn() + fadeIn(),
                exit = scaleOut() + fadeOut(),
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
            ) {
                ScrollToBottomButton(newCount) { scope.launch { listState.animateScrollToItem(0) } }
            }
        }
    }
}

@Composable
private fun CenterNote(text: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, color = CrokTheme.colors.textSecondary, textAlign = TextAlign.Center)
    }
}

@Composable
private fun SessionHeader(state: SessionUiState) {
    val colors = CrokTheme.colors
    Column {
        Text(state.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        val subtitleSize = 13.sp
        if (state.connection != ConnectionState.Connected) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
                Spacer(Modifier.width(6.dp))
                Text(connectionText(state.connection), fontSize = subtitleSize, color = colors.textSecondary, maxLines = 1)
            }
        } else {
            when (state.phase) {
                SessionPhase.Working -> WorkingDots(stringResource(R.string.session_status_working).trimEnd('…', '.'), colors.accent, fontSize = subtitleSize)
                SessionPhase.Waiting -> Text(
                    stringResource(R.string.session_status_waiting, state.deviceName),
                    fontSize = subtitleSize,
                    color = colors.warning,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                SessionPhase.Idle -> Text(stringResource(R.string.session_status_idle, state.deviceName), fontSize = subtitleSize, color = colors.textSecondary, maxLines = 1)
                SessionPhase.Offline -> Text(
                    // The computer may be online with this session closed (or only on its disk).
                    stringResource(if (state.deviceOnline) R.string.session_status_not_running else R.string.session_status_offline, state.deviceName),
                    fontSize = subtitleSize,
                    color = colors.textTertiary,
                    maxLines = 1,
                )
                SessionPhase.Error -> Text(stringResource(R.string.session_status_error, state.deviceName), fontSize = subtitleSize, color = colors.danger, maxLines = 1)
            }
        }
    }
}

/** Telegram's pinned-message bar, for the plan: "Plan 3/7 · Run the tests"; tap for the whole list. */
@Composable
private fun PlanBar(summary: PlanSummary, plan: List<PlanEntry>, expanded: Boolean, onToggle: () -> Unit) {
    val colors = CrokTheme.colors
    Column(Modifier.fillMaxWidth().background(colors.bar).animateContentSize()) {
        HorizontalDivider(color = colors.divider, thickness = 0.5.dp)
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.width(2.dp).height(34.dp).background(colors.accent))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.plan_bar, summary.done, summary.total),
                    color = colors.accent,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                summary.current?.let {
                    Text(it, color = colors.textPrimary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Icon(
                if (expanded) CrokIcons.ExpandLess else CrokIcons.ExpandMore,
                contentDescription = stringResource(if (expanded) R.string.cd_collapse else R.string.cd_expand),
                tint = colors.textSecondary,
            )
        }
        if (expanded) {
            Column(Modifier.padding(start = 28.dp, end = 16.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                plan.forEach { PlanEntryRow(it) }
            }
        }
        HorizontalDivider(color = colors.divider, thickness = 0.5.dp)
    }
}

@Composable
fun PlanEntryRow(entry: PlanEntry) {
    val colors = CrokTheme.colors
    Row(verticalAlignment = Alignment.Top) {
        Box(Modifier.padding(top = 2.dp).size(16.dp), contentAlignment = Alignment.Center) {
            when (entry.status) {
                PlanSummary.COMPLETED -> Icon(CrokIcons.CheckCircle, contentDescription = null, tint = colors.success, modifier = Modifier.size(16.dp))
                PlanSummary.IN_PROGRESS -> Box(Modifier.size(10.dp).clip(CircleShape).background(colors.accent))
                else -> Box(
                    Modifier
                        .size(12.dp)
                        .clip(CircleShape)
                        .background(colors.divider)
                        .padding(2.dp)
                        .clip(CircleShape)
                        .background(colors.bar),
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        Text(
            entry.content,
            fontSize = 14.sp,
            color = if (entry.status == PlanSummary.COMPLETED) colors.textSecondary else colors.textPrimary,
            fontWeight = if (entry.status == PlanSummary.IN_PROGRESS) FontWeight.Medium else FontWeight.Normal,
        )
    }
}

@Composable
private fun ScrollToBottomButton(count: Int, onClick: () -> Unit) {
    val colors = CrokTheme.colors
    Box {
        SmallFloatingActionButton(
            onClick = onClick,
            containerColor = colors.sheet,
            contentColor = colors.textSecondary,
            shape = CircleShape,
        ) {
            Icon(CrokIcons.ArrowDown, contentDescription = stringResource(R.string.transcript_scroll_bottom))
        }
        if (count > 0) {
            Box(
                Modifier
                    .align(Alignment.TopCenter)
                    .offset(y = (-10).dp)
                    .clip(CircleShape)
                    .background(colors.accent)
                    .padding(horizontal = 6.dp, vertical = 1.dp),
            ) {
                Text(if (count > 99) "99+" else count.toString(), color = colors.onAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/** Message field with Send, or Stop while a turn runs (Telegram's streaming-stop button); blocked while offline. */
@Composable
private fun Composer(state: SessionUiState, draft: String, actions: SessionActions) {
    val colors = CrokTheme.colors
    Column(
        Modifier
            .fillMaxWidth()
            .background(colors.bar)
            .navigationBarsPadding()
            .imePadding(),
    ) {
        HorizontalDivider(color = colors.divider, thickness = 0.5.dp)
        if (!state.canSend) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(CrokIcons.Laptop, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text(
                    when {
                        state.gone -> stringResource(R.string.session_gone)
                        // Online computer, session not running there: closed, or only listed from its disk.
                        state.deviceOnline -> stringResource(R.string.composer_not_running, state.deviceName)
                        else -> stringResource(R.string.composer_offline, state.deviceName)
                    },
                    color = colors.textSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.testTag("composer-blocked"),
                )
            }
            return@Column
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.Bottom) {
            TextField(
                value = draft,
                onValueChange = actions.onDraft,
                placeholder = { Text(stringResource(R.string.composer_placeholder, state.deviceName), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                maxLines = 6,
                shape = RoundedCornerShape(22.dp),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = colors.card,
                    unfocusedContainerColor = colors.card,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    cursorColor = colors.accent,
                ),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(6.dp))
            val blank = draft.isBlank()
            if (state.running && blank) {
                RoundAction(CrokIcons.Stop, stringResource(R.string.composer_stop), colors.danger, Color.White, onClick = actions.onStop)
            } else {
                if (state.running) {
                    IconButton(onClick = actions.onStop, modifier = Modifier.padding(bottom = 4.dp)) {
                        Icon(CrokIcons.Stop, contentDescription = stringResource(R.string.composer_stop), tint = colors.danger)
                    }
                }
                RoundAction(
                    CrokIcons.Send,
                    stringResource(R.string.composer_send),
                    if (blank) colors.card else colors.accent,
                    if (blank) colors.textTertiary else colors.onAccent,
                    enabled = !blank,
                    onClick = actions.onSend,
                )
            }
        }
    }
}

@Composable
private fun RoundAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    background: Color,
    tint: Color,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .padding(bottom = 4.dp)
            .size(48.dp)
            .clip(CircleShape)
            .background(background)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(22.dp))
    }
}
