package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionFilter
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.ui.common.ConnectionTitle
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.InitialsAvatar
import dev.chenli.crok.mobile.ui.common.WorkingDots
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.launch

/** What the session list can ask its host to do. */
data class SessionsActions(
    val onOpen: (SessionRow) -> Unit = {},
    val onFilter: (SessionFilter) -> Unit = {},
    val onQuery: (String) -> Unit = {},
    val onSwiping: (Boolean) -> Unit = {},
    val onTogglePin: (SessionRow) -> Unit = {},
    val onToggleArchive: (SessionRow) -> Unit = {},
    val onStop: (SessionRow) -> Unit = {},
    val onLinkComputer: () -> Unit = {},
)

@Composable
fun SessionsScreen(viewModel: SessionsViewModel, onOpen: (SessionRow) -> Unit, onLinkComputer: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val resources = LocalResources.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is SessionsEvent.Archived -> {
                    val result = snackbar.showSnackbar(
                        resources.getString(R.string.sessions_archived_snackbar),
                        actionLabel = resources.getString(R.string.action_undo),
                        withDismissAction = false,
                    )
                    if (result == SnackbarResult.ActionPerformed) viewModel.unarchive(event.sessionDocId)
                }
                is SessionsEvent.Failed -> snackbar.showSnackbar(resources.getString(R.string.sessions_action_failed, event.message))
            }
        }
    }
    SessionsContent(
        state = state,
        snackbar = snackbar,
        actions = SessionsActions(
            onOpen = onOpen,
            onFilter = viewModel::setFilter,
            onQuery = viewModel::setQuery,
            onSwiping = viewModel::setSwiping,
            onTogglePin = viewModel::togglePin,
            onToggleArchive = viewModel::toggleArchive,
            onStop = viewModel::stop,
            onLinkComputer = onLinkComputer,
        ),
    )
}

@Composable
fun SessionsContent(
    state: SessionsUiState,
    actions: SessionsActions,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
) {
    val colors = CrokTheme.colors
    var searching by rememberSaveable { mutableStateOf(state.query.isNotEmpty()) }
    val swipingRows = remember { mutableStateOf(emptySet<String>()) }

    Scaffold(
        containerColor = colors.screen,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column(Modifier.background(colors.bar)) {
                if (searching) {
                    SearchBar(
                        query = state.query,
                        onQuery = actions.onQuery,
                        onClose = {
                            searching = false
                            actions.onQuery("")
                        },
                    )
                } else {
                    TopAppBar(
                        title = { ConnectionTitle(state.connection, stringResource(R.string.sessions_title)) },
                        actions = {
                            IconButton(onClick = { searching = true }) {
                                Icon(CrokIcons.Search, contentDescription = stringResource(R.string.sessions_search))
                            }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.bar),
                    )
                }
                FilterTabs(state, actions.onFilter)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.loading -> CircularProgressIndicator(Modifier.align(Alignment.Center), color = colors.accent)
                state.rows.isEmpty() -> EmptyState(state, actions.onLinkComputer)
                else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 8.dp)) {
                    items(state.rows, key = { it.id }, contentType = { "session" }) { row ->
                        SwipeableSessionRow(
                            row = row,
                            now = state.now,
                            actions = actions,
                            onSwiping = { active ->
                                val next = if (active) swipingRows.value + row.id else swipingRows.value - row.id
                                if (next != swipingRows.value) {
                                    swipingRows.value = next
                                    actions.onSwiping(next.isNotEmpty())
                                }
                            },
                            modifier = Modifier.animateItem(),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchBar(query: String, onQuery: (String) -> Unit, onClose: () -> Unit) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    TopAppBar(
        navigationIcon = {
            IconButton(onClick = onClose) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
        },
        title = {
            TextField(
                value = query,
                onValueChange = onQuery,
                placeholder = { Text(stringResource(R.string.sessions_search_hint)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
        },
        actions = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQuery("") }) { Icon(CrokIcons.Close, contentDescription = stringResource(R.string.cd_clear)) }
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = CrokTheme.colors.bar),
    )
}

/** All · one tab per computer · Archived (Telegram's folder tabs). */
@Composable
private fun FilterTabs(state: SessionsUiState, onFilter: (SessionFilter) -> Unit) {
    val colors = CrokTheme.colors
    val filters = buildList {
        add(SessionFilter.All to stringResource(R.string.filter_all))
        state.tabs.forEach { add(SessionFilter.Computer(it.deviceId) to it.name) }
        add(SessionFilter.Archived to stringResource(R.string.filter_archived))
    }
    val selected = filters.indexOfFirst { it.first == state.filter }.coerceAtLeast(0)
    PrimaryScrollableTabRow(
        selectedTabIndex = selected,
        containerColor = colors.bar,
        contentColor = colors.accent,
        edgePadding = 8.dp,
        minTabWidth = 64.dp,
        divider = { HorizontalDivider(color = colors.divider) },
    ) {
        filters.forEachIndexed { index, (filter, label) ->
            Tab(
                selected = index == selected,
                onClick = { onFilter(filter) },
                selectedContentColor = colors.accent,
                unselectedContentColor = colors.textSecondary,
                text = { Text(label, maxLines = 1, fontWeight = if (index == selected) FontWeight.SemiBold else FontWeight.Normal) },
            )
        }
    }
}

@Composable
private fun EmptyState(state: SessionsUiState, onLinkComputer: () -> Unit) {
    val colors = CrokTheme.colors
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        when {
            state.query.isNotBlank() -> Text(stringResource(R.string.sessions_no_results), color = colors.textSecondary)
            state.filter == SessionFilter.Archived -> {
                IconBadge(CrokIcons.Archive, colors.textSecondary, size = 72.dp)
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.sessions_archived_empty), color = colors.textSecondary, textAlign = TextAlign.Center)
            }
            else -> {
                IconBadge(CrokIcons.Laptop, colors.accent, size = 88.dp)
                Spacer(Modifier.height(20.dp))
                Text(
                    stringResource(R.string.sessions_empty_title),
                    style = MaterialTheme.typography.titleLarge,
                    color = colors.textPrimary,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.sessions_empty_body),
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.widthIn(max = 360.dp),
                )
                Spacer(Modifier.height(20.dp))
                Button(
                    onClick = onLinkComputer,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
                ) {
                    Icon(CrokIcons.QrCode, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.sessions_link_computer))
                }
            }
        }
    }
}

@Composable
private fun SwipeableSessionRow(
    row: SessionRow,
    now: Long,
    actions: SessionsActions,
    onSwiping: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = CrokTheme.colors
    val scope = rememberCoroutineScope()
    val dismiss = rememberSwipeToDismissBoxState(positionalThreshold = { distance -> distance * 0.3f })
    LaunchedEffect(dismiss) {
        snapshotFlow { dismiss.dismissDirection != SwipeToDismissBoxValue.Settled }.collect(onSwiping)
    }
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier,
        backgroundContent = {
            val direction = dismiss.dismissDirection
            val (background, icon, label, alignment) = when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> SwipeVisual(
                    colors.swipePin,
                    CrokIcons.Pin,
                    stringResource(if (row.pinned) R.string.action_unpin else R.string.action_pin),
                    Alignment.CenterStart,
                )
                SwipeToDismissBoxValue.EndToStart -> SwipeVisual(
                    colors.swipeArchive,
                    if (row.archived) CrokIcons.Unarchive else CrokIcons.Archive,
                    stringResource(if (row.archived) R.string.action_unarchive else R.string.action_archive),
                    Alignment.CenterEnd,
                )
                SwipeToDismissBoxValue.Settled -> SwipeVisual(Color.Transparent, null, "", Alignment.Center)
            }
            Box(Modifier.fillMaxSize().background(background).padding(horizontal = 24.dp), contentAlignment = alignment) {
                if (icon != null) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(icon, contentDescription = null, tint = Color.White)
                        Text(label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }
        },
        enableDismissFromStartToEnd = !row.archived,
        onDismiss = { direction ->
            when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> actions.onTogglePin(row)
                SwipeToDismissBoxValue.EndToStart -> actions.onToggleArchive(row)
                SwipeToDismissBoxValue.Settled -> Unit
            }
            scope.launch { dismiss.reset() }
        },
    ) {
        SessionRowItem(row, now, actions)
    }
}

private data class SwipeVisual(
    val background: Color,
    val icon: androidx.compose.ui.graphics.vector.ImageVector?,
    val label: String,
    val alignment: Alignment,
)

/** Telegram's DialogCell, for a session: avatar, title and time, computer · folder, preview or state, badge. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionRowItem(row: SessionRow, now: Long, actions: SessionsActions, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    var menu by remember { mutableStateOf(false) }
    val folder = SessionList.folderName(row.cwd)
    val dimmed = !row.online
    val effectiveNow = if (now > 0) now else System.currentTimeMillis()
    val time = formatter.listTime(RelativeTime.listTime(row.lastActivityAt, effectiveNow, formatter.zone))

    Box(modifier.background(colors.screen)) {
        Column(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = { actions.onOpen(row) }, onLongClick = { menu = true }),
        ) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 80.dp).padding(start = 12.dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                InitialsAvatar(folder, key = folder, size = 54.dp, dimmed = dimmed, online = row.online)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            row.title.ifBlank { folder },
                            style = MaterialTheme.typography.titleMedium,
                            fontSize = 16.sp,
                            color = if (dimmed) colors.textSecondary else colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(time, fontSize = 13.sp, color = if (row.unread > 0 && !dimmed) colors.accent else colors.textTertiary)
                    }
                    Text(
                        "${row.deviceName} · $folder",
                        fontSize = 13.sp,
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) {
                            when {
                                row.isWaiting -> NeedsApprovalChip()
                                row.isRunning -> WorkingDots(stringResource(R.string.sessions_working), colors.accent)
                                else -> Preview(row, dimmed)
                            }
                        }
                        if (row.unread > 0) {
                            Spacer(Modifier.width(8.dp))
                            UnreadBadge(row.unread, muted = dimmed)
                        } else if (row.pinned) {
                            Spacer(Modifier.width(8.dp))
                            val pinned = stringResource(R.string.cd_pinned)
                            Icon(
                                CrokIcons.Pin,
                                contentDescription = pinned,
                                tint = colors.textTertiary,
                                modifier = Modifier.size(18.dp).rotate(45f),
                            )
                        }
                    }
                }
            }
            HorizontalDivider(Modifier.padding(start = 78.dp), color = colors.divider, thickness = 0.5.dp)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (row.isRunning) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_stop), color = colors.danger) },
                    leadingIcon = { Icon(CrokIcons.Stop, contentDescription = null, tint = colors.danger) },
                    onClick = {
                        menu = false
                        actions.onStop(row)
                    },
                )
            }
            if (!row.archived) {
                DropdownMenuItem(
                    text = { Text(stringResource(if (row.pinned) R.string.action_unpin else R.string.action_pin)) },
                    leadingIcon = { Icon(CrokIcons.Pin, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onTogglePin(row)
                    },
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(if (row.archived) R.string.action_unarchive else R.string.action_archive)) },
                leadingIcon = { Icon(if (row.archived) CrokIcons.Unarchive else CrokIcons.Archive, contentDescription = null) },
                onClick = {
                    menu = false
                    actions.onToggleArchive(row)
                },
            )
        }
    }
}

@Composable
private fun Preview(row: SessionRow, dimmed: Boolean) {
    val colors = CrokTheme.colors
    val preview = row.preview?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
    val you = stringResource(R.string.sessions_you)
    val text = buildAnnotatedString {
        if (row.previewKind == EventKind.USER && preview.isNotEmpty()) {
            withStyle(SpanStyle(color = if (dimmed) colors.textSecondary else colors.textPrimary)) { append(you) }
        }
        append(preview)
    }
    Text(
        text,
        fontSize = 14.sp,
        color = colors.textSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun NeedsApprovalChip() {
    val colors = CrokTheme.colors
    Row(
        Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(colors.warningContainer)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(CrokIcons.Warning, contentDescription = null, tint = colors.warning, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(4.dp))
        Text(stringResource(R.string.sessions_needs_approval), color = colors.warning, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun UnreadBadge(count: Int, muted: Boolean) {
    val colors = CrokTheme.colors
    val description = pluralStringResource(R.plurals.sessions_unread, count, count)
    Box(
        Modifier
            .heightIn(min = 22.dp)
            .widthIn(min = 22.dp)
            .clip(CircleShape)
            .background(if (muted) colors.badgeMuted else colors.accent)
            .padding(horizontal = 6.dp)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (count > 99) "99+" else count.toString(),
            color = if (muted) Color.White else colors.onAccent,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}
