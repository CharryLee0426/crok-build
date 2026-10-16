package dev.chenli.crok.mobile.ui.common

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.logic.Avatars
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** A circle with initials and a stable colour (projects, devices, people without a picture). */
@Composable
fun InitialsAvatar(
    name: String,
    key: String,
    size: Dp,
    modifier: Modifier = Modifier,
    dimmed: Boolean = false,
    online: Boolean = false,
) {
    val colors = CrokTheme.colors
    val background = colors.avatars[Avatars.colorIndex(key, colors.avatars.size)]
    Box(modifier.size(size)) {
        Box(
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(if (dimmed) background.copy(alpha = 0.45f) else background),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                Avatars.initials(name),
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = (size.value * 0.38f).sp,
                maxLines = 1,
            )
        }
        if (online) {
            val dot = size * 0.28f
            val description = stringResource(R.string.cd_online)
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .semantics { contentDescription = description }
                    .size(dot)
                    .clip(CircleShape)
                    .background(colors.screen)
                    .padding(dot * 0.18f)
                    .clip(CircleShape)
                    .background(colors.online),
            )
        }
    }
}

/** An icon in a tinted circle (devices, tool kinds, settings rows). */
@Composable
fun IconBadge(icon: ImageVector, tint: Color, modifier: Modifier = Modifier, size: Dp = 36.dp) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(size * 0.55f))
    }
}

private object ImageMemory {
    val cache = LruCache<String, ImageBitmap>(16)
}

/** The account picture from GitHub / Google; falls back to initials. */
@Composable
fun AccountAvatar(name: String, imageUrl: String?, size: Dp, modifier: Modifier = Modifier) {
    val bitmap by produceState(initialValue = imageUrl?.let { ImageMemory.cache.get(it) }, imageUrl) {
        val url = imageUrl?.takeIf { it.startsWith("https://") } ?: return@produceState
        if (value != null) return@produceState
        value = withContext(Dispatchers.IO) {
            runCatching {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 10_000
                connection.readTimeout = 10_000
                try {
                    connection.inputStream.use { BitmapFactory.decodeStream(it) }?.asImageBitmap()
                } finally {
                    connection.disconnect()
                }
            }.getOrNull()
        }?.also { ImageMemory.cache.put(url, it) }
    }
    val image = bitmap
    if (image != null) {
        Image(image, contentDescription = null, contentScale = ContentScale.Crop, modifier = modifier.size(size).clip(CircleShape))
    } else {
        InitialsAvatar(name.ifBlank { "?" }, key = name, size = size, modifier = modifier)
    }
}

/**
 * The title that turns into the connection state (Telegram's "Waiting for network…" / "Connecting…" / "Updating…"),
 * with a small spinner. [state] should already be delayed for display.
 */
@Composable
fun ConnectionTitle(state: ConnectionState, title: String, modifier: Modifier = Modifier) {
    AnimatedContent(
        targetState = state,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        modifier = modifier,
        label = "connection-title",
    ) { current ->
        if (current == ConnectionState.Connected) {
            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = CrokTheme.colors.accent,
                )
                Spacer(Modifier.width(10.dp))
                Text(connectionText(current), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
fun connectionText(state: ConnectionState): String = when (state) {
    ConnectionState.WaitingForNetwork -> stringResource(R.string.connection_waiting_network)
    ConnectionState.Connecting -> stringResource(R.string.connection_connecting)
    ConnectionState.Updating -> stringResource(R.string.connection_updating)
    ConnectionState.Connected -> ""
}

/** "working…" with dots that keep moving (Telegram's typing indicator, iOS ChatListTypingNode). */
@Composable
fun WorkingDots(text: String, color: Color, modifier: Modifier = Modifier, fontSize: androidx.compose.ui.unit.TextUnit = 14.sp) {
    var dots by remember { mutableIntStateOf(1) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(400)
            dots = dots % 3 + 1
        }
    }
    Row(modifier) {
        Text(text, color = color, fontSize = fontSize, maxLines = 1)
        Text(".".repeat(dots).padEnd(3, ' '), color = color, fontSize = fontSize, maxLines = 1)
    }
}

/** A grouped settings section: an optional header, then rows on a card. */
@Composable
fun Section(
    modifier: Modifier = Modifier,
    header: String? = null,
    footer: String? = null,
    content: @Composable () -> Unit,
) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        if (header != null) {
            Text(
                header,
                style = MaterialTheme.typography.labelLarge,
                color = CrokTheme.colors.accent,
                modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 8.dp),
            )
        } else {
            Spacer(Modifier.size(16.dp))
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(CrokTheme.colors.card),
        ) {
            content()
        }
        if (footer != null) {
            Text(
                footer,
                style = MaterialTheme.typography.bodySmall,
                color = CrokTheme.colors.textSecondary,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
            )
        }
    }
}

/** A row in a [Section]: optional leading icon, title, optional subtitle, trailing content. */
@Composable
fun SectionRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    richSubtitle: AnnotatedString? = null,
    leading: (@Composable () -> Unit)? = null,
    titleColor: Color = CrokTheme.colors.textPrimary,
    subtitleColor: Color = CrokTheme.colors.textSecondary,
    divider: Boolean = false,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    Column(modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            leading?.invoke()
            Column(Modifier.weight(1f)) {
                Text(title, color = titleColor, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (richSubtitle != null) {
                    Text(richSubtitle, color = subtitleColor, style = MaterialTheme.typography.bodyMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
                } else if (subtitle != null) {
                    Text(subtitle, color = subtitleColor, style = MaterialTheme.typography.bodyMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
            trailing?.invoke(this)
        }
        if (divider) HorizontalDivider(Modifier.padding(start = if (leading != null) 66.dp else 16.dp), color = CrokTheme.colors.divider)
    }
}

/** A key / value line (session info, device details). */
@Composable
fun InfoLine(label: String, value: String, modifier: Modifier = Modifier, mono: Boolean = false, trailing: (@Composable () -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = CrokTheme.colors.textSecondary, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.width(120.dp))
        Text(
            value,
            color = CrokTheme.colors.textPrimary,
            style = if (mono) CrokTheme.codeStyle else MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
        trailing?.invoke()
    }
}

@Composable
fun ConfirmDialog(
    title: String,
    text: String?,
    confirm: String,
    destructive: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = text?.let { { Text(it) } },
        confirmButton = {
            TextButton(onClick = {
                onDismiss()
                onConfirm()
            }) {
                Text(confirm, color = if (destructive) CrokTheme.colors.danger else CrokTheme.colors.accent)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
        containerColor = CrokTheme.colors.sheet,
    )
}

/** The small grey pill for day headers and notices. */
@Composable
fun Pill(text: String, modifier: Modifier = Modifier, color: Color = CrokTheme.colors.textSecondary, background: Color = CrokTheme.colors.card) {
    Text(
        text,
        color = color,
        style = MaterialTheme.typography.labelMedium,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(background)
            .border(0.5.dp, CrokTheme.colors.divider, RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}
