package dev.chenli.crok.mobile.ui.settings

import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.glassBarColors
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.ui.common.ConfirmDialog
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.InfoLine
import dev.chenli.crok.mobile.ui.common.Section
import dev.chenli.crok.mobile.ui.common.SectionRow
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** The Devices screen's list; null while loading. */
data class DevicesUiState(val devices: List<Device>?, val error: String? = null) {
    val current: Device? get() = devices?.firstOrNull { it.isCurrent }
    val computers: List<Device> get() = devices.orEmpty().filter { !it.isCurrent && it.isComputer }
    val phones: List<Device> get() = devices.orEmpty().filter { !it.isCurrent && !it.isComputer }
}

sealed interface DevicesEvent {
    data class SignedOut(val count: Int) : DevicesEvent
    data class Failed(val message: String) : DevicesEvent
}

class DevicesViewModel(private val engine: CrokEngine) : ViewModel() {
    val state: StateFlow<DevicesUiState> = engine.devices.list()
        .map { result -> DevicesUiState(result.getOrNull(), result.exceptionOrNull()?.message) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DevicesUiState(null))

    private val _events = Channel<DevicesEvent>(Channel.BUFFERED)
    val events: Flow<DevicesEvent> = _events.receiveAsFlow()

    fun revoke(device: Device) = act {
        engine.devices.revoke(device.id)
        _events.trySend(DevicesEvent.SignedOut(1))
    }

    fun revokeOthers() = act {
        val count = engine.devices.revokeOthers()
        _events.trySend(DevicesEvent.SignedOut(count))
    }

    private fun act(block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _events.trySend(DevicesEvent.Failed(e.message ?: e.javaClass.simpleName))
            }
        }
    }
}

data class DevicesActions(
    val onBack: () -> Unit = {},
    val onRevoke: (Device) -> Unit = {},
    val onRevokeOthers: () -> Unit = {},
    val onSignOutThisPhone: () -> Unit = {},
)

@Composable
fun DevicesScreen(viewModel: DevicesViewModel, actions: DevicesActions) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val resources = LocalResources.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            val message = when (event) {
                is DevicesEvent.SignedOut -> resources.getQuantityString(R.plurals.devices_signed_out, event.count, event.count)
                is DevicesEvent.Failed -> resources.getString(R.string.devices_failed, event.message)
            }
            snackbar.showSnackbar(message)
        }
    }
    DevicesContent(state, System.currentTimeMillis(), actions.copy(onRevoke = viewModel::revoke, onRevokeOthers = viewModel::revokeOthers), snackbar)
}

@Composable
fun DevicesContent(
    state: DevicesUiState,
    now: Long,
    actions: DevicesActions,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
    initiallySelected: String? = null,
) {
    val colors = CrokTheme.colors
    var selectedId by rememberSaveable { mutableStateOf(initiallySelected) }
    var confirmOthers by remember { mutableStateOf(false) }
    GlassScaffold(
        background = colors.grouped,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = actions.onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                },
                title = { Text(stringResource(R.string.devices_title)) },
                colors = glassBarColors(),
            )
        },
    ) { padding ->
        val devices = state.devices
        if (devices == null) {
            Column(Modifier.fillMaxSize().padding(padding), horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(Modifier.height(64.dp))
                CircularProgressIndicator(color = colors.accent)
            }
            return@GlassScaffold
        }
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 24.dp),
        ) {
            state.current?.let { current ->
                Section(header = stringResource(R.string.devices_this_device), footer = stringResource(R.string.devices_this_device_note)) {
                    DeviceRow(current, now, divider = false) { selectedId = current.id }
                }
            }
            if (state.computers.isNotEmpty()) {
                Section(header = stringResource(R.string.devices_computers)) {
                    state.computers.forEachIndexed { index, device ->
                        DeviceRow(device, now, divider = index < state.computers.lastIndex) { selectedId = device.id }
                    }
                }
            }
            if (state.phones.isNotEmpty()) {
                Section(header = stringResource(R.string.devices_phones)) {
                    state.phones.forEachIndexed { index, device ->
                        DeviceRow(device, now, divider = index < state.phones.lastIndex) { selectedId = device.id }
                    }
                }
            }
            if (state.computers.isNotEmpty() || state.phones.isNotEmpty()) {
                Section(footer = stringResource(R.string.devices_footer)) {
                    SectionRow(
                        stringResource(R.string.devices_sign_out_others),
                        leading = { IconBadge(CrokIcons.Logout, colors.danger) },
                        titleColor = colors.danger,
                        onClick = { confirmOthers = true },
                    )
                }
            }
        }
    }

    val selected = state.devices?.firstOrNull { it.id == selectedId }
    if (selected != null) {
        DeviceSheet(
            device = selected,
            now = now,
            onDismiss = { selectedId = null },
            onSignOut = {
                selectedId = null
                if (selected.isCurrent) actions.onSignOutThisPhone() else actions.onRevoke(selected)
            },
        )
    }
    if (confirmOthers) {
        ConfirmDialog(
            title = stringResource(R.string.devices_sign_out_others_title),
            text = stringResource(R.string.devices_sign_out_others_body),
            confirm = stringResource(R.string.settings_sign_out),
            destructive = true,
            onConfirm = actions.onRevokeOthers,
            onDismiss = { confirmOthers = false },
        )
    }
}

@Composable
private fun DeviceRow(device: Device, now: Long, divider: Boolean, onClick: () -> Unit) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    val online = device.online || device.isCurrent
    val status = if (online) {
        stringResource(R.string.devices_online)
    } else {
        stringResource(R.string.devices_last_seen, formatter.ago(RelativeTime.ago(device.lastSeenAt, now, formatter.zone)))
    }
    val sessions = if (device.isComputer && device.liveSessionCount > 0) {
        " · " + pluralStringResource(R.plurals.devices_live_sessions, device.liveSessionCount, device.liveSessionCount)
    } else {
        ""
    }
    // Telegram's active sessions: "online" in the accent colour, otherwise when it was last seen.
    val subtitle = buildAnnotatedString {
        append(listOf(device.client, device.platform).filter { it.isNotBlank() }.joinToString(" · "))
        append('\n')
        if (online) withStyle(SpanStyle(color = colors.accent)) { append(status) } else append(status)
        append(sessions)
    }
    SectionRow(
        title = device.name,
        richSubtitle = subtitle,
        subtitleColor = colors.textSecondary,
        leading = { IconBadge(if (device.isComputer) CrokIcons.Laptop else CrokIcons.Phone, if (device.online || device.isCurrent) colors.accent else colors.textTertiary, size = 40.dp) },
        divider = divider,
        onClick = onClick,
    )
}

@Composable
private fun DeviceSheet(device: Device, now: Long, onDismiss: () -> Unit, onSignOut: () -> Unit) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    var confirm by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.grouped) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            IconBadge(if (device.isComputer) CrokIcons.Laptop else CrokIcons.Phone, colors.accent, size = 72.dp)
            Spacer(Modifier.height(12.dp))
            Text(device.name, style = MaterialTheme.typography.titleLarge, color = colors.textPrimary)
            Text(
                if (device.online || device.isCurrent) stringResource(R.string.devices_online)
                else stringResource(R.string.devices_last_seen, formatter.ago(RelativeTime.ago(device.lastSeenAt, now, formatter.zone))),
                color = if (device.online || device.isCurrent) colors.accent else colors.textSecondary,
                style = MaterialTheme.typography.bodyMedium,
            )
            Section {
                InfoLine(stringResource(R.string.devices_platform), device.platform)
                InfoLine(stringResource(R.string.devices_app), device.client)
                InfoLine(stringResource(R.string.devices_linked), formatter.dateTime(device.createdAt))
                if (!device.isCurrent) InfoLine(stringResource(R.string.devices_last_active), formatter.dateTime(device.lastSeenAt))
            }
            Section {
                SectionRow(
                    stringResource(if (device.isCurrent) R.string.settings_sign_out else R.string.devices_sign_out_device),
                    leading = { IconBadge(CrokIcons.Logout, colors.danger) },
                    titleColor = colors.danger,
                    onClick = { confirm = true },
                )
            }
        }
    }
    if (confirm) {
        ConfirmDialog(
            title = if (device.isCurrent) stringResource(R.string.sign_out_title) else stringResource(R.string.devices_sign_out_device_title, device.name),
            text = if (device.isCurrent) stringResource(R.string.sign_out_body) else stringResource(R.string.devices_sign_out_device_body),
            confirm = stringResource(R.string.settings_sign_out),
            destructive = true,
            onConfirm = onSignOut,
            onDismiss = { confirm = false },
        )
    }
}
