package dev.chenli.crok.mobile.ui.signin

import android.content.ClipData
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.auth.PendingSignIn
import dev.chenli.crok.mobile.auth.SignInError
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.Mono
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The Crok mark on a sage tile, like the launcher icon. */
@Composable
fun CrokMark(size: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(androidx.compose.ui.graphics.Color(0xFF41634C)),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(R.drawable.ic_crok_mark),
            contentDescription = null,
            colorFilter = ColorFilter.tint(androidx.compose.ui.graphics.Color.White),
            modifier = Modifier.size(size * 0.62f),
        )
    }
}

/** The Welcome screen. There is no server to choose: the app signs in to the relay built into it. */
data class WelcomeUiState(
    val error: SignInError?,
    val busy: Boolean,
    val demoAllowed: Boolean,
)

@Composable
fun signInErrorText(error: SignInError): String = when (error) {
    SignInError.Network -> stringResource(R.string.error_network)
    SignInError.Denied -> stringResource(R.string.signin_error_denied)
    SignInError.Expired -> stringResource(R.string.signin_error_expired)
    SignInError.Revoked -> stringResource(R.string.signin_error_revoked)
    SignInError.NotConfigured -> stringResource(R.string.signin_error_not_configured)
    is SignInError.Other -> stringResource(R.string.error_generic, error.message)
}

@Composable
fun WelcomeScreen(
    state: WelcomeUiState,
    onContinue: () -> Unit,
    onDemo: () -> Unit,
) {
    val colors = CrokTheme.colors

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.screen)
            .safeDrawingPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(72.dp))
        CrokMark(96.dp)
        Spacer(Modifier.height(28.dp))
        Text(
            stringResource(R.string.welcome_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.welcome_body),
            style = MaterialTheme.typography.bodyLarge,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 420.dp),
        )
        Spacer(Modifier.height(36.dp))
        Button(
            onClick = onContinue,
            enabled = !state.busy,
            modifier = Modifier.fillMaxWidth().widthIn(max = 420.dp).height(52.dp),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) {
            if (state.busy) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.onAccent)
            } else {
                Text(stringResource(R.string.welcome_continue), fontSize = 16.sp, fontWeight = FontWeight.Medium)
            }
        }
        state.error?.let { error ->
            Spacer(Modifier.height(14.dp))
            Text(signInErrorText(error), color = colors.danger, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.weight(1f).heightIn(min = 24.dp))
        Text(
            stringResource(R.string.welcome_note),
            style = MaterialTheme.typography.bodySmall,
            color = colors.textTertiary,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 420.dp),
        )
        if (state.demoAllowed) {
            TextButton(onClick = onDemo) { Text(stringResource(R.string.welcome_demo), color = colors.accent) }
        }
        Spacer(Modifier.height(16.dp))
    }
}

data class WaitingUiState(
    val pending: PendingSignIn,
    val offline: Boolean,
    /** Set when no browser could open the approval page: the web app's address to open elsewhere. */
    val browserMissing: String? = null,
)

@Composable
fun WaitingScreen(
    state: WaitingUiState,
    onOpenAgain: () -> Unit,
    onCancel: () -> Unit,
    now: () -> Long = System::currentTimeMillis,
) {
    val colors = CrokTheme.colors
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    var clock by remember { mutableLongStateOf(now()) }
    LaunchedEffect(state.pending.deviceCode) {
        while (true) {
            clock = now()
            delay(1_000)
        }
    }
    val pending = state.pending
    val hasLink = pending.browserUrl != null

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.screen)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(72.dp))
        CrokMark(72.dp)
        Spacer(Modifier.height(24.dp))
        Text(
            stringResource(R.string.waiting_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(if (hasLink) R.string.waiting_body else R.string.waiting_body_no_link),
            style = MaterialTheme.typography.bodyLarge,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 420.dp),
        )
        Spacer(Modifier.height(24.dp))
        val copyLabel = stringResource(R.string.waiting_copy_code)
        Text(
            pending.userCode,
            fontFamily = Mono,
            fontSize = 34.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 4.sp,
            color = colors.textPrimary,
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(colors.card)
                .border(1.dp, colors.divider, RoundedCornerShape(16.dp))
                .clickable { scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("crok", pending.userCode))) } }
                .semantics { contentDescription = copyLabel }
                .padding(horizontal = 24.dp, vertical = 16.dp),
        )
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
            Text(
                stringResource(R.string.waiting_expires, RelativeTime.countdown(pending.expiresAt - clock)),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.textSecondary,
            )
        }
        if (state.offline) {
            Spacer(Modifier.height(10.dp))
            Column(Modifier.widthIn(max = 420.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(CrokIcons.Warning, contentDescription = null, tint = colors.warning, modifier = Modifier.size(18.dp))
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(R.string.waiting_offline),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.warning,
                    textAlign = TextAlign.Center,
                )
            }
        }
        state.browserMissing?.let { web ->
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.signin_no_browser, web),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.warning,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 420.dp),
            )
        }
        if (pending.deviceName.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.waiting_device, pending.deviceName),
                style = MaterialTheme.typography.bodySmall,
                color = colors.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(32.dp))
        if (hasLink) {
            FilledTonalButton(
                onClick = onOpenAgain,
                modifier = Modifier.fillMaxWidth().widthIn(max = 420.dp).height(50.dp),
                shape = RoundedCornerShape(14.dp),
            ) { Text(stringResource(R.string.waiting_open_again), fontSize = 16.sp) }
            Spacer(Modifier.height(8.dp))
        }
        TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth().widthIn(max = 420.dp)) {
            Text(stringResource(R.string.action_cancel), color = colors.textSecondary)
        }
        Spacer(Modifier.height(16.dp))
    }
}
