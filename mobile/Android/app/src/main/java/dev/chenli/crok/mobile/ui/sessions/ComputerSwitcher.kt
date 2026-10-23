package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.ComputerAccount
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.ui.common.ComputerAvatar
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassMenuDivider
import dev.chenli.crok.mobile.ui.common.GlassMenuRow
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme

/** "Online", or "last seen …" (the Sessions title's subtitle and the computer rows). */
@Composable
fun computerStatus(computer: ComputerAccount, now: Long = System.currentTimeMillis()): String {
    if (computer.online) return stringResource(R.string.cd_online)
    if (computer.lastSeenAt <= 0) return stringResource(R.string.computer_offline)
    val formatter = rememberFormatter()
    return stringResource(R.string.devices_last_seen, formatter.ago(RelativeTime.ago(computer.lastSeenAt, now, formatter.zone)))
}

/**
 * The computer switcher (mobile/DESIGN.md): every computer with its avatar, name and "N unread" or its status, a
 * checkmark on the selected one, then Link a computer. Long press on the Profile tab, or the Sessions title.
 */
@Composable
fun ColumnScope.ComputerSwitcherItems(
    computers: List<ComputerAccount>,
    selectedId: String?,
    onSelect: (String) -> Unit,
    onLinkComputer: () -> Unit,
    dismiss: () -> Unit,
) {
    val colors = CrokTheme.colors
    computers.forEach { computer ->
        val selected = computer.deviceId == selectedId
        val status = computerStatus(computer)
        GlassMenuRow(
            title = computer.name,
            subtitle = if (computer.unread > 0) pluralStringResource(R.plurals.switcher_unread, computer.unread, computer.unread) else status,
            subtitleColor = if (computer.unread == 0 && computer.online) colors.accent else colors.textSecondary,
            leading = { ComputerAvatar(computer.name, computer.deviceId, computer.online, 34.dp, ringColor = colors.sheet) },
            trailing = if (selected) ({ Icon(CrokIcons.Check, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp)) }) else null,
            modifier = Modifier.testTag("switch-${computer.deviceId}"),
            onClick = {
                dismiss()
                onSelect(computer.deviceId)
            },
        )
    }
    if (computers.isNotEmpty()) GlassMenuDivider()
    GlassMenuRow(
        title = stringResource(R.string.settings_link_computer),
        titleColor = colors.accent,
        leading = { Icon(CrokIcons.Add, contentDescription = null, tint = colors.accent, modifier = Modifier.size(34.dp).testTag("switch-link")) },
        onClick = {
            dismiss()
            onLinkComputer()
        },
    )
}
