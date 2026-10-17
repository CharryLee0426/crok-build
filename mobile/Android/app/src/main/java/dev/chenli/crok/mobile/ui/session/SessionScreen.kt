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
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.PendingInteraction
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.logic.PlanSummary
import dev.chenli.crok.mobile.logic.TranscriptItem
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.WorkingDots
import dev.chenli.crok.mobile.ui.common.connectionText
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import dev.chenli.crok.mobile.logic.CommandEntry
import dev.chenli.crok.mobile.logic.ComposerCommands
import dev.chenli.crok.mobile.logic.LocalCommand
import dev.chenli.crok.mobile.ui.common.GlassCircle
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.GlassShapes
import dev.chenli.crok.mobile.ui.common.GlassStyle
import dev.chenli.crok.mobile.ui.common.glass
import dev.chenli.crok.mobile.ui.common.glassBarColors
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

data class SessionActions(
    val onBack: () -> Unit = {},
    val onInfo: () -> Unit = {},
    val onDraft: (String) -> Unit = {},
    val onSend: () -> Unit = {},
    val onStop: () -> Unit = {},
    /** Answers the pending permission request (`interactionId`, `optionId`). */
    val onAnswer: (String, String) -> Unit = { _, _ -> },
    val onLoadMore: () -> Unit = {},
    val onReload: () -> Unit = {},
    /** A row of the command list. */
    val onPickCommand: (CommandEntry) -> Unit = {},
    val transcript: TranscriptActions = TranscriptActions(),
)

@Composable
fun SessionScreen(
    viewModel: SessionViewModel,
    onBack: () -> Unit,
    onNewSession: (NewSessionTarget, String?) -> Unit,
    infoSheet: @Composable (sessionDocId: String, onDismiss: () -> Unit) -> Unit,
) {
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
                is SessionEvent.AnswerFailed -> snackbar.showSnackbar(resources.getString(R.string.error_generic, event.message))
                SessionEvent.ShowInfo -> showInfo = true
                is SessionEvent.NewSession -> onNewSession(event.target, event.prompt)
                SessionEvent.NewSessionUnavailable -> snackbar.showSnackbar(resources.getString(R.string.new_session_unavailable))
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
            onAnswer = viewModel::answer,
            onLoadMore = viewModel::loadMore,
            onReload = viewModel::reload,
            onPickCommand = viewModel::pickCommand,
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
                onApplyConfig = viewModel::applyConfig,
            ),
        ),
    )
    val sessionDocId = viewModel.sessionDocId
    if (showInfo && sessionDocId != null) infoSheet(sessionDocId) { showInfo = false }
}

@Composable
fun SessionContent(
    state: SessionUiState,
    draft: String,
    now: Long,
    actions: SessionActions,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
    listState: LazyListState = rememberLazyListState(),
    menuInitiallyOpen: Boolean = false,
) {
    val colors = CrokTheme.colors
    val scope = rememberCoroutineScope()
    var planExpanded by rememberSaveable { mutableStateOf(false) }
    var menuOpen by rememberSaveable { mutableStateOf(menuInitiallyOpen) }

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

    val bot = BotContext(state.models, state.deviceName, state.deviceOnline)
    GlassScaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = actions.onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                    },
                    title = { SessionHeader(state) },
                    actions = {
                        if (state.newSession == null) {
                            IconButton(onClick = actions.onInfo) { Icon(CrokIcons.Info, contentDescription = stringResource(R.string.session_info)) }
                        }
                    },
                    colors = glassBarColors(),
                )
                state.planSummary?.let { summary -> PlanBar(summary, state.plan, planExpanded) { planExpanded = !planExpanded } }
            }
        },
        bottomBar = {
            Composer(
                state = state,
                draft = draft,
                menuOpen = menuOpen,
                onMenu = { menuOpen = !menuOpen },
                actions = actions.copy(
                    onPickCommand = { entry ->
                        menuOpen = false
                        actions.onPickCommand(entry)
                    },
                    onSend = {
                        menuOpen = false
                        actions.onSend()
                    },
                ),
            )
        },
        floating = { padding ->
            AnimatedVisibility(
                visible = !atBottom && state.items.isNotEmpty(),
                enter = scaleIn() + fadeIn(),
                exit = scaleOut() + fadeOut(),
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = padding.calculateBottomPadding() + 12.dp),
            ) {
                ScrollToBottomButton(newCount) { scope.launch { listState.animateScrollToItem(0) } }
            }
        },
    ) { padding ->
        val inner = Modifier.fillMaxSize().padding(padding)
        when {
            state.gone -> CenterNote(stringResource(R.string.session_gone), inner)
            state.newSession != null && state.items.isEmpty() -> NewSessionNote(state.newSession, inner)
            !state.loaded && state.error != null -> Column(inner.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Text(stringResource(R.string.transcript_load_failed, state.error), color = colors.textSecondary, textAlign = TextAlign.Center)
                TextButton(onClick = actions.onReload) { Text(stringResource(R.string.action_retry), color = colors.accent) }
            }
            !state.loaded -> Box(inner, contentAlignment = Alignment.Center) { CircularProgressIndicator(color = colors.accent) }
            state.historyOnComputer && state.deviceOnline -> Column(inner.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp, color = colors.accent)
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.session_history_loading, state.deviceName), color = colors.textSecondary, textAlign = TextAlign.Center)
            }
            state.historyOnComputer -> Column(inner.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(CrokIcons.Laptop, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(40.dp))
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.session_history_offline, state.deviceName), color = colors.textSecondary, textAlign = TextAlign.Center)
            }
            state.items.isEmpty() -> CenterNote(stringResource(R.string.transcript_empty), inner)
            else -> LazyColumn(
                state = listState,
                reverseLayout = true,
                modifier = Modifier.fillMaxSize(),
                // Rows scroll under the glass bars: the padding only keeps the ends clear of them.
                contentPadding = PaddingValues(top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 12.dp),
            ) {
                items(state.items, key = { it.key }, contentType = { it::class.simpleName }) { item ->
                    TranscriptRow(item, now, actions.transcript, bot)
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
    }
}

@Composable
private fun CenterNote(text: String, modifier: Modifier = Modifier) {
    Box(modifier.padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, color = CrokTheme.colors.textSecondary, textAlign = TextAlign.Center)
    }
}

/** The new-session screen's empty transcript (Telegram's new chat): where the session will run. */
@Composable
private fun NewSessionNote(target: NewSessionTarget, modifier: Modifier) {
    val colors = CrokTheme.colors
    Box(modifier.padding(32.dp), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                // Part of the content the glass bars read: a backdrop of its own would read itself, so frosted only.
                .glass(GlassShapes.rounded(22.dp), backdrop = null)
                .padding(horizontal = 20.dp, vertical = 16.dp)
                .testTag("new-session-note"),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(CrokIcons.Folder, contentDescription = null, tint = colors.accent, modifier = Modifier.size(28.dp))
            Spacer(Modifier.height(8.dp))
            Text(
                stringResource(R.string.new_session_starts_in, target.path, target.deviceName),
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.new_session_first_prompt),
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun SessionHeader(state: SessionUiState) {
    val colors = CrokTheme.colors
    Column {
        val newSession = state.newSession
        Text(
            if (newSession != null) stringResource(R.string.new_session_title) else state.title,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
        )
        val subtitleSize = 13.sp
        when {
            state.connection != ConnectionState.Connected -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
                Spacer(Modifier.width(6.dp))
                Text(connectionText(state.connection), fontSize = subtitleSize, color = colors.textSecondary, maxLines = 1)
            }
            newSession != null -> Text(
                stringResource(R.string.new_session_subtitle, newSession.projectName, newSession.deviceName),
                fontSize = subtitleSize,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            state.starting && state.phase != SessionPhase.Error -> Text(
                stringResource(R.string.session_starting),
                fontSize = subtitleSize,
                color = colors.accent,
                maxLines = 1,
            )
            else -> when (state.phase) {
                SessionPhase.Working -> WorkingDots(stringResource(R.string.session_status_working).trimEnd('…', '.'), colors.accent, fontSize = subtitleSize)
                SessionPhase.Waiting -> Text(
                    stringResource(R.string.session_status_waiting, state.deviceName),
                    fontSize = subtitleSize,
                    color = colors.warning,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                SessionPhase.Idle -> Text(stringResource(R.string.session_status_idle, state.deviceName), fontSize = subtitleSize, color = colors.textSecondary, maxLines = 1)
                // Only for an offline computer: a session nobody runs on an online one is idle (a prompt opens it there).
                SessionPhase.Offline -> Text(
                    stringResource(R.string.session_status_offline, state.deviceName),
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
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        HorizontalDivider(color = colors.divider.copy(alpha = 0.6f), thickness = 0.5.dp)
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
        GlassCircle(onClick = onClick, size = 44.dp) {
            Icon(CrokIcons.ArrowDown, contentDescription = stringResource(R.string.transcript_scroll_bottom), tint = colors.textSecondary)
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

/**
 * The composer, floating on glass over the transcript: the Menu button (Telegram's bot menu: a blue pill, "Menu" while
 * the field is empty, just the icon while typing), the field, and Send — or Stop while a turn runs (Telegram's
 * streaming-stop button). Above it the pending permission request, and the command list when the Menu button or a
 * leading `/` opened it. Blocked only while the computer is offline (a session nobody runs opens for a prompt).
 */
@Composable
private fun Composer(state: SessionUiState, draft: String, menuOpen: Boolean, onMenu: () -> Unit, actions: SessionActions) {
    val colors = CrokTheme.colors
    Column(
        Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .imePadding()
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        if (!state.canSend) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .glass(GlassShapes.rounded(22.dp), GlassStyle.Bar)
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(CrokIcons.Laptop, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text(
                    if (state.gone) stringResource(R.string.session_gone) else stringResource(R.string.composer_offline, state.deviceName),
                    color = colors.textSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.testTag("composer-blocked"),
                )
            }
            return@Column
        }
        state.pending?.let { PermissionCard(it, state.deviceName, state.answering, actions.onAnswer) }
        val suggestions = if (state.hasMenu) {
            ComposerCommands.suggestions(draft, menuOpen, state.localCommands, state.sessionCommands)
        } else {
            null
        }
        if (!suggestions.isNullOrEmpty()) CommandList(suggestions, actions.onPickCommand)
        Row(verticalAlignment = Alignment.Bottom) {
            Row(
                Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp)
                    .glass(GlassShapes.rounded(24.dp))
                    .padding(start = 6.dp, end = 2.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                if (state.hasMenu) {
                    MenuPill(expanded = draft.isEmpty(), open = menuOpen, onClick = onMenu)
                }
                val newSession = state.newSession
                val placeholder = if (newSession != null) {
                    stringResource(R.string.composer_new_placeholder, newSession.projectName)
                } else {
                    stringResource(R.string.composer_placeholder, state.deviceName)
                }
                BasicTextField(
                    value = draft,
                    onValueChange = actions.onDraft,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textPrimary),
                    cursorBrush = SolidColor(colors.accent),
                    maxLines = 6,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 10.dp, vertical = 7.dp)
                        .semantics { contentDescription = placeholder }
                        .testTag("composer-field"),
                    decorationBox = { field ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (draft.isEmpty()) {
                                Text(
                                    placeholder,
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = colors.textTertiary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            field()
                        }
                    },
                )
                if (state.running && draft.isNotBlank()) {
                    IconButton(onClick = actions.onStop, modifier = Modifier.size(36.dp)) {
                        Icon(CrokIcons.Stop, contentDescription = stringResource(R.string.composer_stop), tint = colors.danger)
                    }
                }
            }
            Spacer(Modifier.width(6.dp))
            val blank = draft.isBlank()
            if (state.running && blank) {
                RoundAction(CrokIcons.Stop, stringResource(R.string.composer_stop), colors.danger, Color.White, onClick = actions.onStop)
            } else if (blank) {
                GlassCircle(onClick = {}, size = 48.dp) {
                    Icon(CrokIcons.Send, contentDescription = stringResource(R.string.composer_send), tint = colors.textTertiary, modifier = Modifier.size(22.dp))
                }
            } else {
                RoundAction(CrokIcons.Send, stringResource(R.string.composer_send), colors.accent, colors.onAccent, onClick = actions.onSend)
            }
        }
    }
}

/** Telegram's bot menu button: a blue pill with ☰ and "Menu", only ☰ while there is text. */
@Composable
private fun MenuPill(expanded: Boolean, open: Boolean, onClick: () -> Unit) {
    val colors = CrokTheme.colors
    val label = stringResource(R.string.composer_menu)
    Row(
        Modifier
            .padding(bottom = 2.dp)
            .height(32.dp)
            .clip(GlassShapes.capsule)
            .background(if (open) colors.accent.copy(alpha = 0.85f) else colors.accent)
            .clickable(onClickLabel = label, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(horizontal = if (expanded) 12.dp else 8.dp)
            .animateContentSize()
            .testTag("menu-pill"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (open) CrokIcons.Close else CrokIcons.Menu, contentDescription = null, tint = colors.onAccent, modifier = Modifier.size(18.dp))
        if (expanded) {
            Spacer(Modifier.width(6.dp))
            Text(label, color = colors.onAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

/**
 * The command list above the composer (Telegram's BotCommandsMenuView): `/name` in bold with its input hint greyed after
 * it, the description under; the phone's own commands first, then the session's.
 */
@Composable
private fun CommandList(entries: List<CommandEntry>, onPick: (CommandEntry) -> Unit) {
    val colors = CrokTheme.colors
    LazyColumn(
        Modifier
            .padding(bottom = 8.dp)
            .fillMaxWidth()
            .heightIn(max = 300.dp)
            .glass(GlassShapes.rounded(22.dp), GlassStyle.Bar)
            .testTag("command-list"),
        contentPadding = PaddingValues(vertical = 6.dp),
    ) {
        items(entries, key = { (if (it.local != null) "l:" else "s:") + it.name }) { entry ->
            val description = entry.local?.let { localDescription(it) } ?: entry.description
            val hint = entry.local?.let { localHint(it) } ?: entry.hint
            Column(
                Modifier
                    .fillMaxWidth()
                    .clickable { onPick(entry) }
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Text(
                    buildAnnotatedString {
                        withStyle(SpanStyle(fontWeight = FontWeight.Bold, color = colors.textPrimary)) { append("/" + entry.name) }
                        if (!hint.isNullOrBlank()) withStyle(SpanStyle(color = colors.textTertiary)) { append(" $hint") }
                    },
                    fontSize = 15.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (description.isNotBlank()) {
                    Text(description, fontSize = 13.sp, color = colors.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun localDescription(command: LocalCommand): String = stringResource(
    when (command) {
        LocalCommand.New -> R.string.cmd_new
        LocalCommand.Model -> R.string.cmd_model
        LocalCommand.Think -> R.string.cmd_think
        LocalCommand.Stop -> R.string.cmd_stop
        LocalCommand.Info -> R.string.cmd_info
    },
)

@Composable
private fun localHint(command: LocalCommand): String? = when (command) {
    LocalCommand.New -> stringResource(R.string.cmd_hint_new)
    LocalCommand.Model -> stringResource(R.string.cmd_hint_model)
    LocalCommand.Think -> stringResource(R.string.cmd_hint_think)
    else -> null
}

/**
 * A permission request the session waits on (run this command, edit that file), with its choices: any of the person's
 * devices may answer, the first answer counts, and the card goes once the computer has it. Allowing choices are filled,
 * the others outlined; all are disabled while this phone's answer is on its way.
 */
@Composable
private fun PermissionCard(pending: PendingInteraction, computer: String, answering: Boolean, onAnswer: (String, String) -> Unit) {
    val colors = CrokTheme.colors
    Column(
        Modifier
            .padding(bottom = 8.dp)
            .fillMaxWidth()
            .clip(GlassShapes.rounded(20.dp))
            .background(colors.warningContainer.copy(alpha = 0.96f))
            .padding(12.dp)
            .testTag("permission-card"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(CrokIcons.Warning, contentDescription = null, tint = colors.warning, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(
                stringResource(R.string.permission_asks, computer),
                color = colors.warning,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.semantics { heading() },
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            pending.title,
            color = colors.textPrimary,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            // A new request is read out when it arrives.
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        pending.detail?.takeIf { it.isNotBlank() }?.let { detail ->
            Spacer(Modifier.height(6.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 96.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(colors.card)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            ) {
                Text(detail, style = CrokTheme.codeStyle, color = colors.textPrimary)
            }
        }
        Spacer(Modifier.height(10.dp))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            val shape = RoundedCornerShape(20.dp)
            val padding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)
            pending.options.forEach { option ->
                val label = option.name.ifBlank { option.optionId }
                val onClick = { onAnswer(pending.id, option.optionId) }
                if (option.allows) {
                    Button(
                        onClick = onClick,
                        enabled = !answering,
                        shape = shape,
                        contentPadding = padding,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
                    ) { Text(label, fontSize = 14.sp) }
                } else {
                    OutlinedButton(onClick = onClick, enabled = !answering, shape = shape, contentPadding = padding) {
                        Text(label, fontSize = 14.sp, color = if (answering) colors.textTertiary else colors.textPrimary)
                    }
                }
            }
            if (answering) {
                val sending = stringResource(R.string.tick_clock)
                CircularProgressIndicator(
                    Modifier.size(18.dp).semantics { contentDescription = sending },
                    strokeWidth = 2.dp,
                    color = colors.textSecondary,
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
