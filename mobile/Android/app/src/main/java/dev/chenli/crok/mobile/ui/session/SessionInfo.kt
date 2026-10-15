package dev.chenli.crok.mobile.ui.session

import android.content.ClipData
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionInfoResult
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.ui.common.ConfirmDialog
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.InfoLine
import dev.chenli.crok.mobile.ui.common.Section
import dev.chenli.crok.mobile.ui.common.SectionRow
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/** Fresh numbers from the computer (`commands:requestInfo`), on top of what the relay already has. */
sealed interface InfoRefresh {
    data object Idle : InfoRefresh
    data object Loading : InfoRefresh
    data class Done(val result: SessionInfoResult) : InfoRefresh
    data class Failed(val message: String) : InfoRefresh
}

class SessionInfoViewModel(private val engine: CrokEngine, private val sessionDocId: String) : ViewModel() {
    val detail: StateFlow<SessionDetail?> = engine.sessions.get(sessionDocId)
        .mapNotNull { it.getOrNull() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val _refresh = MutableStateFlow<InfoRefresh>(InfoRefresh.Idle)
    val refresh: StateFlow<InfoRefresh> = _refresh.asStateFlow()

    /** Each time the sheet opens: fresh numbers from the computer, if it is online. */
    suspend fun refreshOnOpen() {
        val current = detail.first { it != null } ?: return
        if (current.online) refreshNow()
    }

    fun refreshNow() {
        if (_refresh.value == InfoRefresh.Loading) return
        _refresh.value = InfoRefresh.Loading
        viewModelScope.launch {
            _refresh.value = try {
                val commandId = engine.commands.requestInfo(sessionDocId)
                val done = withTimeout(INFO_TIMEOUT_MS) {
                    engine.commands.get(commandId)
                        .mapNotNull { it.getOrNull() }
                        .first { it.status == CommandStatus.DONE || it.status == CommandStatus.FAILED }
                }
                if (done.status == CommandStatus.DONE) {
                    SessionInfoResult.from(done.result)?.let { InfoRefresh.Done(it) } ?: InfoRefresh.Idle
                } else {
                    InfoRefresh.Failed(done.error ?: "")
                }
            } catch (e: CancellationException) {
                if (e is kotlinx.coroutines.TimeoutCancellationException) InfoRefresh.Failed("timeout") else throw e
            } catch (e: Exception) {
                InfoRefresh.Failed(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    fun setPinned(pinned: Boolean) = viewModelScope.launch { runCatching { engine.sessions.setPinned(sessionDocId, pinned) } }

    fun setArchived(archived: Boolean) = viewModelScope.launch { runCatching { engine.sessions.setArchived(sessionDocId, archived) } }

    fun remove(onRemoved: () -> Unit) = viewModelScope.launch {
        runCatching { engine.sessions.remove(sessionDocId) }.onSuccess { onRemoved() }
    }

    companion object {
        const val INFO_TIMEOUT_MS = 20_000L
    }
}

data class SessionInfoActions(
    val onPin: (Boolean) -> Unit = {},
    val onArchive: (Boolean) -> Unit = {},
    val onRemove: () -> Unit = {},
    val onCopy: (String) -> Unit = {},
)

@Composable
fun SessionInfoSheet(viewModel: SessionInfoViewModel, onDismiss: () -> Unit, onRemoved: () -> Unit) {
    val detail by viewModel.detail.collectAsStateWithLifecycle()
    val refresh by viewModel.refresh.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    LaunchedEffect(viewModel) { viewModel.refreshOnOpen() }
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = CrokTheme.colors.grouped,
    ) {
        val current = detail
        if (current == null) {
            CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally).padding(32.dp), color = CrokTheme.colors.accent)
        } else {
            SessionInfoContent(
                detail = current,
                refresh = refresh,
                now = System.currentTimeMillis(),
                actions = SessionInfoActions(
                    onPin = viewModel::setPinned,
                    onArchive = viewModel::setArchived,
                    onRemove = {
                        viewModel.remove {
                            onDismiss()
                            onRemoved()
                        }
                    },
                    onCopy = { text -> scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("crok", text))) } },
                ),
            )
        }
    }
}

@Composable
fun SessionInfoContent(detail: SessionDetail, refresh: InfoRefresh, now: Long, actions: SessionInfoActions, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    val fresh = (refresh as? InfoRefresh.Done)?.result
    val usage = detail.usage
    val model = fresh?.model ?: detail.model
    val effort = fresh?.effort ?: detail.effort
    val branch = fresh?.gitBranch ?: detail.gitBranch
    val input = fresh?.inputTokens ?: usage?.inputTokens
    val output = fresh?.outputTokens ?: usage?.outputTokens
    val cached = fresh?.cachedTokens ?: usage?.cachedTokens
    val reasoning = fresh?.reasoningTokens ?: usage?.reasoningTokens
    val cost = fresh?.costUsd ?: usage?.costUsd
    val contextUsed = fresh?.contextUsed ?: usage?.contextTokens
    val contextWindow = fresh?.contextWindow ?: usage?.contextWindow
    var confirmRemove by remember { mutableStateOf(false) }

    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 16.dp)) {
        Text(
            detail.title,
            style = MaterialTheme.typography.titleLarge,
            color = colors.textPrimary,
            modifier = Modifier.padding(horizontal = 32.dp, vertical = 4.dp),
        )
        when (refresh) {
            InfoRefresh.Loading -> Row(Modifier.padding(horizontal = 32.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.info_refreshing, detail.deviceName), fontSize = 13.sp, color = colors.textSecondary)
            }
            is InfoRefresh.Failed -> Text(
                stringResource(R.string.info_refresh_failed, refresh.message),
                fontSize = 13.sp,
                color = colors.warning,
                modifier = Modifier.padding(horizontal = 32.dp, vertical = 6.dp),
            )
            else -> if (!detail.online) {
                Text(
                    stringResource(R.string.info_offline_note),
                    fontSize = 13.sp,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(horizontal = 32.dp, vertical = 6.dp),
                )
            }
        }

        Section {
            model?.let { InfoLine(stringResource(R.string.info_model), it) }
            effort?.let { InfoLine(stringResource(R.string.info_effort), it) }
            InfoLine(stringResource(R.string.info_folder), SessionList.prettyPath(detail.cwd), mono = true)
            branch?.let { InfoLine(stringResource(R.string.info_branch), it, mono = true) }
            InfoLine(
                stringResource(R.string.info_computer),
                listOf(detail.deviceName, detail.devicePlatform).filter { it.isNotBlank() }.joinToString(" · "),
            )
            InfoLine(
                stringResource(R.string.info_app),
                stringResource(
                    when (detail.app) {
                        "desktop" -> R.string.app_desktop
                        "cli" -> R.string.app_cli
                        else -> R.string.app_tui
                    },
                ),
            )
            if (detail.createdAt > 0) InfoLine(stringResource(R.string.info_started), formatter.dateTime(detail.createdAt))
            if (detail.lastActivityAt > 0) {
                InfoLine(stringResource(R.string.info_last_activity), formatter.ago(RelativeTime.ago(detail.lastActivityAt, now, formatter.zone)))
            }
        }

        if (input != null || output != null || cost != null || contextWindow != null) {
            Section {
                if (input != null || output != null) {
                    val extra = listOfNotNull(
                        cached?.takeIf { it > 0 }?.let { stringResource(R.string.info_tokens_cached, formatter.compact(it)) },
                        reasoning?.takeIf { it > 0 }?.let { stringResource(R.string.info_tokens_reasoning, formatter.compact(it)) },
                    )
                    val main = stringResource(R.string.info_tokens_value, formatter.compact(input ?: 0), formatter.compact(output ?: 0))
                    InfoLine(stringResource(R.string.info_tokens), (listOf(main) + extra).joinToString("\n"))
                }
                cost?.let { InfoLine(stringResource(R.string.info_cost), formatter.cost(it)) }
                if (contextUsed != null && contextWindow != null && contextWindow > 0) {
                    val percent = ((contextUsed * 100) / contextWindow).toInt().coerceIn(0, 100)
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                        Row {
                            Text(stringResource(R.string.info_context), color = colors.textSecondary, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.width(120.dp))
                            Text(
                                stringResource(R.string.info_context_value, formatter.compact(contextUsed), formatter.compact(contextWindow), percent),
                                color = colors.textPrimary,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        LinearProgressIndicator(
                            progress = { percent / 100f },
                            modifier = Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)),
                            color = if (percent >= 85) colors.warning else colors.accent,
                            trackColor = colors.divider,
                            strokeCap = StrokeCap.Round,
                            drawStopIndicator = {},
                        )
                    }
                }
            }
        }

        if (detail.plan.isNotEmpty()) {
            Section(header = stringResource(R.string.plan_title)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    detail.plan.forEach { PlanEntryRow(it) }
                }
            }
        }

        Section {
            InfoLine(
                stringResource(R.string.info_session_id),
                detail.sessionId,
                mono = true,
                trailing = {
                    IconButton(onClick = { actions.onCopy(detail.sessionId) }) {
                        Icon(CrokIcons.Copy, contentDescription = stringResource(R.string.action_copy), tint = colors.textSecondary, modifier = Modifier.size(18.dp))
                    }
                },
            )
        }

        Section {
            if (!detail.archived) {
                SectionRow(
                    stringResource(if (detail.pinned) R.string.action_unpin else R.string.action_pin),
                    leading = { Icon(CrokIcons.Pin, contentDescription = null, tint = colors.accent) },
                    titleColor = colors.accent,
                    divider = true,
                    onClick = { actions.onPin(!detail.pinned) },
                )
            }
            SectionRow(
                stringResource(if (detail.archived) R.string.action_unarchive else R.string.action_archive),
                leading = { Icon(if (detail.archived) CrokIcons.Unarchive else CrokIcons.Archive, contentDescription = null, tint = colors.accent) },
                titleColor = colors.accent,
                divider = !detail.online,
                onClick = { actions.onArchive(!detail.archived) },
            )
            if (!detail.online) {
                SectionRow(
                    stringResource(R.string.info_remove),
                    leading = { Icon(CrokIcons.Delete, contentDescription = null, tint = colors.danger) },
                    titleColor = colors.danger,
                    onClick = { confirmRemove = true },
                )
            }
        }
    }
    if (confirmRemove) {
        ConfirmDialog(
            title = stringResource(R.string.info_remove_title),
            text = stringResource(R.string.info_remove_body, detail.deviceName),
            confirm = stringResource(R.string.action_remove),
            destructive = true,
            onConfirm = actions.onRemove,
            onDismiss = { confirmRemove = false },
        )
    }
}
