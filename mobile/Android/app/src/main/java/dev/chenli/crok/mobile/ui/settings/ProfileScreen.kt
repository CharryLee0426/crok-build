package dev.chenli.crok.mobile.ui.settings

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.Color
import androidx.core.net.toUri
import dev.chenli.crok.mobile.BuildConfig
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.ComputerAccount
import dev.chenli.crok.mobile.ui.AccountInfo
import dev.chenli.crok.mobile.ui.common.AccountAvatar
import dev.chenli.crok.mobile.ui.common.ComputerAvatar
import dev.chenli.crok.mobile.ui.common.ConfirmDialog
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.Section
import dev.chenli.crok.mobile.ui.common.SectionRow
import dev.chenli.crok.mobile.ui.common.SettingsIcon
import dev.chenli.crok.mobile.ui.common.glassBarColors
import dev.chenli.crok.mobile.ui.sessions.UnreadBadge
import dev.chenli.crok.mobile.ui.sessions.computerStatus
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.util.Locale

/** Profile (mobile/DESIGN.md "Profile"): the person, their computers, settings, about. */
data class ProfileUiState(
    val account: AccountInfo,
    val computers: List<ComputerAccount> = emptyList(),
    val selectedId: String? = null,
    val deviceCount: Int? = null,
    val version: String = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
    val demo: Boolean = false,
)

data class ProfileActions(
    val onSelectComputer: (String) -> Unit = {},
    val onLinkComputer: () -> Unit = {},
    val onDevices: () -> Unit = {},
    val onAppearance: () -> Unit = {},
    val onLanguage: (() -> Unit)? = null,
    val onOpenUrl: (String) -> Unit = {},
    val onSignOut: () -> Unit = {},
)

/** The developer's pages (Contact the developer on GitHub / X). */
object DeveloperLinks {
    const val GITHUB = "https://github.com/CharryLee0426"
    const val X = "https://x.com/CharryLee426"
}

/** The row icons' colours (Telegram's and iOS Settings' coloured squares). */
private object RowColors {
    val devices = Color(0xFFF09A37)
    val appearance = Color(0xFF3D8BF2)
    val language = Color(0xFFA65EEB)
    val version = Color(0xFF8E8E93)
    val github = Color(0xFF24292F)
    val x = Color(0xFF000000)
}

@Composable
fun ProfileScreen(state: ProfileUiState, actions: ProfileActions) {
    val context = LocalContext.current
    val language: (() -> Unit)? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        {
            val intent = Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.fromParts("package", context.packageName, null))
            runCatching { context.startActivity(intent) }
        }
    } else {
        null
    }
    ProfileContent(
        state,
        actions.copy(
            onLanguage = language,
            onOpenUrl = { url -> runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) } },
        ),
    )
}

@Composable
fun ProfileContent(state: ProfileUiState, actions: ProfileActions) {
    val colors = CrokTheme.colors
    var confirmSignOut by remember { mutableStateOf(false) }
    GlassScaffold(
        background = colors.grouped,
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.profile_title)) }, colors = glassBarColors())
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                // Inside the scroll: the rows scroll up under the glass bars.
                .padding(top = padding.calculateTopPadding() + 12.dp, bottom = padding.calculateBottomPadding() + 24.dp),
        ) {
            // The person, centred (Telegram's Settings header).
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).testTag("profile-header"), horizontalAlignment = Alignment.CenterHorizontally) {
                AccountAvatar(state.account.name, state.account.imageUrl, 96.dp)
                Spacer(Modifier.height(12.dp))
                Text(
                    state.account.name,
                    style = MaterialTheme.typography.titleLarge,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                )
                state.account.email?.takeIf { it != state.account.name }?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (state.demo) {
                    Text(
                        stringResource(R.string.settings_demo_note),
                        color = colors.warning,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            }

            // The computers (the person's accounts), then Link a computer (Telegram's Add Account).
            Section {
                state.computers.forEach { computer ->
                    ComputerRow(computer, selected = computer.deviceId == state.selectedId, onClick = { actions.onSelectComputer(computer.deviceId) })
                }
                SectionRow(
                    stringResource(R.string.settings_link_computer),
                    titleColor = colors.accent,
                    leading = { Icon(CrokIcons.Add, contentDescription = null, tint = colors.accent, modifier = Modifier.size(32.dp)) },
                    onClick = actions.onLinkComputer,
                    modifier = Modifier.testTag("profile-link"),
                )
            }

            Section {
                SectionRow(
                    stringResource(R.string.settings_devices),
                    leading = { SettingsIcon(CrokIcons.Devices, RowColors.devices) },
                    divider = true,
                    onClick = actions.onDevices,
                    modifier = Modifier.testTag("profile-devices"),
                ) {
                    state.deviceCount?.let { Text(it.toString(), color = colors.textSecondary, fontSize = 15.sp) }
                    Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary)
                }
                SectionRow(
                    stringResource(R.string.settings_appearance),
                    leading = { SettingsIcon(CrokIcons.Palette, RowColors.appearance) },
                    divider = actions.onLanguage != null,
                    onClick = actions.onAppearance,
                    modifier = Modifier.testTag("profile-appearance"),
                ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
                actions.onLanguage?.let { openLanguage ->
                    val locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT
                    SectionRow(
                        stringResource(R.string.settings_language),
                        leading = { SettingsIcon(CrokIcons.Globe, RowColors.language) },
                        onClick = openLanguage,
                    ) {
                        Text(locale.getDisplayLanguage(locale).replaceFirstChar { it.titlecase(locale) }, color = colors.textSecondary, fontSize = 15.sp, maxLines = 1)
                        Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary)
                    }
                }
            }

            Section {
                SectionRow(
                    stringResource(R.string.settings_version),
                    leading = { SettingsIcon(CrokIcons.Info, RowColors.version) },
                    divider = true,
                ) { Text(state.version, color = colors.textSecondary, fontSize = 15.sp) }
                if (state.demo) {
                    SectionRow(stringResource(R.string.profile_mode), leading = { SettingsIcon(CrokIcons.Bulb, RowColors.version) }, divider = true) {
                        Text(stringResource(R.string.profile_mode_demo), color = colors.textSecondary, fontSize = 15.sp)
                    }
                }
                SectionRow(
                    stringResource(R.string.profile_contact_github),
                    leading = { SettingsIcon(painterResource(R.drawable.ic_github), RowColors.github, outlined = colors.isDark) },
                    divider = true,
                    onClick = { actions.onOpenUrl(DeveloperLinks.GITHUB) },
                    modifier = Modifier.testTag("profile-github"),
                ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
                SectionRow(
                    stringResource(R.string.profile_contact_x),
                    leading = { SettingsIcon(painterResource(R.drawable.ic_x_logo), RowColors.x, outlined = colors.isDark) },
                    onClick = { actions.onOpenUrl(DeveloperLinks.X) },
                    modifier = Modifier.testTag("profile-x"),
                ) { Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary) }
            }

            Section {
                SectionRow(
                    stringResource(R.string.settings_sign_out),
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

/** A computer in Profile's list: avatar, name, its status; the unread count and a checkmark on the selected one. */
@Composable
private fun ComputerRow(computer: ComputerAccount, selected: Boolean, onClick: () -> Unit) {
    val colors = CrokTheme.colors
    SectionRow(
        computer.name,
        subtitle = computerStatus(computer),
        subtitleColor = if (computer.online) colors.accent else colors.textSecondary,
        leading = { ComputerAvatar(computer.name, computer.deviceId, computer.online, 34.dp, ringColor = colors.card) },
        divider = true,
        onClick = onClick,
        modifier = Modifier.testTag("profile-computer-${computer.deviceId}"),
    ) {
        if (computer.unread > 0) UnreadBadge(computer.unread, muted = false)
        if (selected) {
            Icon(CrokIcons.Check, contentDescription = stringResource(R.string.cd_selected), tint = colors.accent, modifier = Modifier.size(22.dp))
        }
    }
}
