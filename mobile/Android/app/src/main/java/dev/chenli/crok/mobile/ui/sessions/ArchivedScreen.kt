package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.glassBarColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** One computer's archived sessions (Telegram's Archived Chats). */
data class ArchivedUiState(
    val computerName: String = "",
    /** Null until the relay answered. */
    val rows: List<SessionRow>? = null,
    val now: Long = 0,
)

class ArchivedViewModel(private val engine: CrokEngine, private val deviceId: String, computerName: String) : ViewModel() {
    private val _events = Channel<SessionsEvent>(Channel.BUFFERED)
    val events: Flow<SessionsEvent> = _events.receiveAsFlow()

    val state: StateFlow<ArchivedUiState> = engine.sessions.archived().map { result ->
        ArchivedUiState(computerName, result.getOrNull()?.filter { it.deviceId == deviceId }, engine.clock())
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ArchivedUiState(computerName))

    fun unarchive(row: SessionRow) {
        viewModelScope.launch {
            try {
                engine.sessions.setArchived(row.id, false)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _events.trySend(SessionsEvent.Failed(e.message ?: e.javaClass.simpleName))
            }
        }
    }
}

@Composable
fun ArchivedScreen(viewModel: ArchivedViewModel, onBack: () -> Unit, onOpen: (SessionRow) -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val resources = LocalResources.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            if (event is SessionsEvent.Failed) snackbar.showSnackbar(resources.getString(R.string.sessions_action_failed, event.message))
        }
    }
    ArchivedContent(state, onBack, TopicActions(onOpen = onOpen, onToggleArchive = viewModel::unarchive), snackbar)
}

@Composable
fun ArchivedContent(state: ArchivedUiState, onBack: () -> Unit, actions: TopicActions, snackbar: SnackbarHostState = remember { SnackbarHostState() }) {
    val colors = CrokTheme.colors
    GlassScaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                },
                title = {
                    Column {
                        Text(
                            stringResource(R.string.sessions_archived_title),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(state.computerName, fontSize = 13.sp, color = colors.textSecondary, maxLines = 1)
                    }
                },
                colors = glassBarColors(),
            )
        },
    ) { padding ->
        val rows = state.rows
        when {
            rows == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }
            rows.isEmpty() -> Column(
                Modifier.fillMaxSize().padding(padding).padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                IconBadge(CrokIcons.Archive, colors.textSecondary, size = 72.dp)
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.sessions_archived_none), style = MaterialTheme.typography.titleMedium, color = colors.textPrimary)
                Spacer(Modifier.height(6.dp))
                Text(stringResource(R.string.sessions_archived_hint), color = colors.textSecondary, textAlign = TextAlign.Center)
            }
            else -> LazyColumn(
                Modifier.fillMaxSize().testTag("archived-list"),
                contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 8.dp),
            ) {
                items(rows, key = { it.id }, contentType = { "topic" }) { row ->
                    SwipeableTopicRow(row, state.now, actions, projectLine = true, modifier = Modifier.animateItem())
                }
            }
        }
    }
}
