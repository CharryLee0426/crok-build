package dev.chenli.crok.mobile.ui.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.Avatars
import dev.chenli.crok.mobile.logic.StableIndex
import dev.chenli.crok.mobile.logic.TopicColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme

/** A colour's top-light gradient (iOS's `Color.gradient`): lighter at the top. */
private fun softGradient(color: Color): Brush = Brush.verticalGradient(listOf(lerp(color, Color.White, 0.12f), color))

/**
 * A session's topic glyph (Telegram's forum topic icon): a speech bubble with a short tail at the bottom left, in one
 * of Telegram's six topic colours picked from the session's id, with the title's first letter in white.
 */
@Composable
fun TopicIcon(title: String, sessionDocId: String, size: Dp, modifier: Modifier = Modifier, dimmed: Boolean = false) {
    val color = Color(TopicColors.all[TopicColors.index(sessionDocId)])
    val brush = remember(color) { Brush.verticalGradient(listOf(lerp(color, Color.White, 0.15f), color)) }
    Box(modifier.size(size).alpha(if (dimmed) 0.55f else 1f), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val s = this.size.minDimension
            val bubble = Path().apply {
                addOval(Rect(Offset(s * 0.06f, s * 0.04f), androidx.compose.ui.geometry.Size(s * 0.88f, s * 0.84f)))
                // The tail: from the circle's lower left out to the corner and back.
                moveTo(s * 0.16f, s * 0.66f)
                lineTo(s * 0.06f, s * 0.97f)
                lineTo(s * 0.42f, s * 0.84f)
                close()
            }
            drawPath(bubble, brush)
        }
        // Too small to read below 18 dp (the forum row's strip): the bubble alone.
        if (size >= 18.dp) {
            Text(
                TopicColors.initial(title),
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = (size.value * 0.40f).sp,
                maxLines = 1,
                modifier = Modifier.padding(bottom = size * 0.08f),
            )
        }
    }
}

/** A project's avatar as a group with topics: a rounded square (30 % corners, Telegram's forum avatar) with initials. */
@Composable
fun ForumAvatar(name: String, size: Dp, modifier: Modifier = Modifier, dimmed: Boolean = false) {
    val colors = CrokTheme.colors
    val base = colors.avatars[Avatars.colorIndex(name, colors.avatars.size)]
    val color = if (dimmed) lerp(base, Color(0xFF8E8E93), 0.85f) else base
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.3f))
            .background(softGradient(color))
            .alpha(if (dimmed) 0.7f else 1f),
        contentAlignment = Alignment.Center,
    ) {
        Text(Avatars.initials(name), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.38f).sp, maxLines = 1)
    }
}

/** A computer as an account: initials on a colour picked from its device id, with the green dot while online. */
@Composable
fun ComputerAvatar(name: String, deviceId: String, online: Boolean, size: Dp, modifier: Modifier = Modifier, ringColor: Color = CrokTheme.colors.screen) {
    val colors = CrokTheme.colors
    val color = colors.avatars[StableIndex.fnv1a(deviceId, colors.avatars.size)]
    Box(modifier.size(size)) {
        Box(
            Modifier.size(size).clip(CircleShape).background(softGradient(color)),
            contentAlignment = Alignment.Center,
        ) {
            Text(Avatars.initials(name), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.38f).sp, maxLines = 1)
        }
        if (online) {
            val dot = size * 0.3f
            val description = stringResource(R.string.cd_online)
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .semantics { contentDescription = description }
                    .size(dot)
                    .clip(CircleShape)
                    .background(ringColor)
                    .padding(dot * 0.18f)
                    .clip(CircleShape)
                    .background(colors.online),
            )
        }
    }
}

/** A Profile row's icon: a white glyph on a solid coloured rounded square (iOS Settings' and Telegram's row icons). */
@Composable
fun SettingsIcon(icon: ImageVector, color: Color, modifier: Modifier = Modifier, size: Dp = 30.dp) {
    Box(
        modifier.size(size).clip(RoundedCornerShape(size * 0.26f)).background(color),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.62f))
    }
}

/** [SettingsIcon] for a drawable glyph (the GitHub and X logos); [outlined] draws a hairline rim for black on black. */
@Composable
fun SettingsIcon(painter: Painter, color: Color, modifier: Modifier = Modifier, size: Dp = 30.dp, outlined: Boolean = false) {
    val shape = RoundedCornerShape(size * 0.26f)
    Box(
        modifier
            .size(size)
            .clip(shape)
            .background(color)
            .then(if (outlined) Modifier.border(0.5.dp, Color.White.copy(alpha = 0.22f), shape) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painter, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.58f))
    }
}
