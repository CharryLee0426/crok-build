package dev.chenli.crok.mobile.ui.session

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.BotCard
import dev.chenli.crok.mobile.logic.BotCardKind
import dev.chenli.crok.mobile.logic.BotCardProblem
import dev.chenli.crok.mobile.logic.ComposerCommands
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.theme.CrokTheme

/** One button of a bot card's inline keyboard. */
private data class KeyboardButton(val id: String, val label: String, val detail: String?, val current: Boolean)

/**
 * The phone's answer to `/model` or `/think` (Telegram's bot message with an inline keyboard under it): the question,
 * then one button per choice — models one per row with the description under the name, thinking levels two per row —
 * the current one marked ✓. A tapped button spins until the computer applied it; then the card says what is set and
 * the keyboard folds away. Without choices (the computer is offline, or its crok too old) it says why.
 */
@Composable
fun BotCardRow(card: BotCard, bot: BotContext, onApply: (cardId: String, value: String) -> Unit) {
    val colors = CrokTheme.colors
    val models = bot.models
    val current = models.current
    // The list is the computer's own (`devices:models`), with the session's copy as the fallback (ModelState.of).
    val unavailable: String? = when {
        card.done != null -> null
        // Not there yet: the buttons come when it arrives.
        models.loading && bot.deviceOnline -> null
        models.models == null && !bot.deviceOnline -> stringResource(R.string.bot_offline, bot.deviceName)
        models.models == null -> stringResource(R.string.bot_no_models, bot.deviceName)
        card.kind == BotCardKind.Think && current?.efforts.isNullOrEmpty() -> stringResource(R.string.bot_no_thinking)
        else -> null
    }
    val buttons: List<KeyboardButton> = if (card.done != null || unavailable != null) {
        emptyList()
    } else if (card.kind == BotCardKind.Model) {
        models.models.orEmpty().map { KeyboardButton(it.id, it.label, it.description, it.id == current?.id) }
    } else {
        val effort = ComposerCommands.currentEffort(current, models.effort)
        current?.efforts.orEmpty().map { KeyboardButton(it.id, it.label, null, it.id == effort?.id) }
    }
    val shape = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomEnd = 18.dp, bottomStart = if (buttons.isEmpty()) 18.dp else 6.dp)
    Column(
        Modifier
            .fillMaxWidth(0.92f)
            .padding(start = 10.dp, top = 10.dp)
            .animateContentSize()
            .testTag("bot-card"),
    ) {
        Column(
            Modifier
                .clip(shape)
                .background(colors.bubbleIn)
                .border(0.5.dp, colors.divider, shape)
                .padding(horizontal = 12.dp, vertical = 9.dp),
        ) {
            val done = card.done
            if (done != null) {
                Text(
                    stringResource(if (card.kind == BotCardKind.Model) R.string.bot_model_done else R.string.bot_think_done, done),
                    color = colors.textPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(CrokIcons.Bulb, contentDescription = null, tint = colors.accent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(
                        stringResource(if (card.kind == BotCardKind.Model) R.string.bot_model_title else R.string.bot_think_title),
                        color = colors.textPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            unavailable?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, color = colors.textSecondary, fontSize = 14.sp)
            }
            when (val problem = card.problem) {
                is BotCardProblem.NoMatch -> ProblemLine(stringResource(R.string.bot_no_match, problem.argument))
                is BotCardProblem.Ambiguous -> ProblemLine(stringResource(R.string.bot_ambiguous, problem.argument))
                is BotCardProblem.Failed -> ProblemLine(stringResource(R.string.bot_failed, problem.message))
                null -> Unit
            }
        }
        if (buttons.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            val busy = card.applying != null
            val perRow = if (card.kind == BotCardKind.Model) 1 else 2
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                buttons.chunked(perRow).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        row.forEach { button ->
                            KeyboardKey(
                                button = button,
                                applying = card.applying == button.id,
                                enabled = !busy,
                                onClick = { onApply(card.id, button.id) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                        // An odd last thinking level keeps its half width.
                        repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProblemLine(text: String) {
    Spacer(Modifier.height(4.dp))
    Text(text, color = CrokTheme.colors.danger, fontSize = 14.sp)
}

@Composable
private fun KeyboardKey(button: KeyboardButton, applying: Boolean, enabled: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val colors = CrokTheme.colors
    val shape = RoundedCornerShape(12.dp)
    val currentLabel = stringResource(R.string.bot_current)
    Row(
        modifier
            .heightIn(min = 44.dp)
            .clip(shape)
            .background(if (button.current) colors.accent.copy(alpha = if (colors.isDark) 0.22f else 0.1f) else colors.bubbleIn)
            .border(0.5.dp, if (button.current) colors.accent.copy(alpha = 0.5f) else colors.divider, shape)
            .clickable(enabled = enabled && !button.current, role = Role.Button, onClick = onClick)
            .then(if (button.current) Modifier.semantics { contentDescription = "${button.label}, $currentLabel" } else Modifier)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), horizontalAlignment = if (button.detail == null) Alignment.CenterHorizontally else Alignment.Start) {
            Text(
                button.label,
                color = if (enabled || applying || button.current) colors.accent else colors.textTertiary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = if (button.detail == null) TextAlign.Center else TextAlign.Start,
            )
            button.detail?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = colors.textSecondary, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        when {
            applying -> CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.accent)
            button.current -> Icon(CrokIcons.Check, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
        }
    }
}
