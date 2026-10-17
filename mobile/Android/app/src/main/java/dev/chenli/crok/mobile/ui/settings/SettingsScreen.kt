package dev.chenli.crok.mobile.ui.settings

import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.glassBarColors
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.BuildConfig
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.ui.common.AccountAvatar
import dev.chenli.crok.mobile.ui.common.ConfirmDialog
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.InfoLine
import dev.chenli.crok.mobile.ui.common.Section
import dev.chenli.crok.mobile.ui.common.SectionRow
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn

data class SettingsUiState(
    val name: String,
    val email: String?,
    val imageUrl: String?,
    val deviceName: String,
    val deviceCount: Int?,
    val server: String,
    val version: String = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
    val demo: Boolean = false,
)

class SettingsViewModel(engine: CrokEngine) : ViewModel() {
    private val account = engine.account

    val state: StateFlow<SettingsUiState> = combine(
        engine.accounts.me().onStart { emit(Result.success(null)) },
        engine.devices.list().onStart { emit(Result.success(emptyList())) },
    ) { me, devices ->
        val user = me.getOrNull()
        SettingsUiState(
            name = user?.name ?: account.user.name ?: account.user.email ?: "",
            email = user?.email ?: account.user.email,
            imageUrl = user?.imageUrl ?: account.user.imageUrl,
            deviceName = user?.device?.name ?: account.deviceName,
            deviceCount = devices.getOrNull()?.size?.takeIf { it > 0 },
            server = account.serverUrl,
            demo = engine.isDemo,
        )
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        SettingsUiState(
            name = account.user.name ?: account.user.email ?: "",
            email = account.user.email,
            imageUrl = account.user.imageUrl,
            deviceName = account.deviceName,
            deviceCount = null,
            server = account.serverUrl,
            demo = engine.isDemo,
        ),
    )
}

data class SettingsActions(
    val onDevices: () -> Unit = {},
    val onLinkComputer: () -> Unit = {},
    val onTheme: (ThemeMode) -> Unit = {},
    val onLanguage: (() -> Unit)? = null,
    val onSignOut: () -> Unit = {},
)

@Composable
fun SettingsScreen(viewModel: SettingsViewModel, theme: ThemeMode, actions: SettingsActions) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val language: (() -> Unit)? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        {
            val intent = Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.fromParts("package", context.packageName, null))
            runCatching { context.startActivity(intent) }
        }
    } else {
        null
    }
    SettingsContent(state, theme, actions.copy(onLanguage = language))
}

@Composable
fun SettingsContent(state: SettingsUiState, theme: ThemeMode, actions: SettingsActions) {
    val colors = CrokTheme.colors
    var confirmSignOut by remember { mutableStateOf(false) }
    GlassScaffold(
        background = colors.grouped,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                colors = glassBarColors(),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                // Inside the scroll: the rows scroll up under the glass bars.
                .padding(top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 24.dp),
        ) {
            // Account
            Row(
                Modifier
                    .padding(horizontal = 16.dp)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(colors.card)
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AccountAvatar(state.name, state.imageUrl, 64.dp)
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(state.name, style = MaterialTheme.typography.titleLarge, color = colors.textPrimary, maxLines = 1)
                    state.email?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1) }
                    Spacer(Modifier.height(2.dp))
                    Text(stringResource(R.string.settings_this_phone, state.deviceName), style = MaterialTheme.typography.bodySmall, color = colors.textTertiary)
                }
            }
            if (state.demo) {
                Text(
                    stringResource(R.string.settings_demo_note),
                    color = colors.warning,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp),
                )
            }

            Section {
                SectionRow(
                    stringResource(R.string.settings_devices),
                    subtitle = state.deviceCount?.let { pluralStringResource(R.plurals.settings_devices_count, it, it) },
                    leading = { IconBadge(CrokIcons.Devices, colors.accent) },
                    divider = true,
                    onClick = actions.onDevices,
                ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
                SectionRow(
                    stringResource(R.string.settings_link_computer),
                    subtitle = stringResource(R.string.settings_link_computer_detail),
                    leading = { IconBadge(CrokIcons.QrCode, colors.accent) },
                    onClick = actions.onLinkComputer,
                ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
            }

            Section(header = stringResource(R.string.settings_appearance)) {
                Row(Modifier.padding(16.dp)) {
                    val options = listOf(
                        ThemeMode.System to R.string.theme_system,
                        ThemeMode.Light to R.string.theme_light,
                        ThemeMode.Dark to R.string.theme_dark,
                    )
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        options.forEachIndexed { index, (mode, label) ->
                            SegmentedButton(
                                selected = theme == mode,
                                onClick = { actions.onTheme(mode) },
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
                actions.onLanguage?.let { openLanguage ->
                    SectionRow(
                        stringResource(R.string.settings_language),
                        leading = { IconBadge(CrokIcons.Translate, colors.accent) },
                        onClick = openLanguage,
                    ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
                }
            }

            Section(header = stringResource(R.string.settings_about)) {
                InfoLine(stringResource(R.string.settings_version), state.version)
                InfoLine(stringResource(R.string.settings_server), state.server, mono = true)
            }

            Section {
                SectionRow(
                    stringResource(R.string.settings_sign_out),
                    leading = { IconBadge(CrokIcons.Logout, colors.danger) },
                    titleColor = colors.danger,
                    onClick = { confirmSignOut = true },
                )
            }
        }
    }
    if (confirmSignOut) {
        ConfirmDialog(
            title = stringResource(R.string.sign_out_title),
            text = stringResource(R.string.sign_out_body),
            confirm = stringResource(R.string.settings_sign_out),
            destructive = true,
            onConfirm = actions.onSignOut,
            onDismiss = { confirmSignOut = false },
        )
    }
}
