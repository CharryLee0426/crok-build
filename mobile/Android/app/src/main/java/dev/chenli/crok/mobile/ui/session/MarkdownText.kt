package dev.chenli.crok.mobile.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.logic.Markdown
import dev.chenli.crok.mobile.logic.MdBlock
import dev.chenli.crok.mobile.logic.MdInline
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.Mono

/** The span styles inline Markdown maps to; built from the theme in the app, plain values in tests. */
data class MarkdownStyles(
    val code: SpanStyle,
    val link: SpanStyle,
)

/** Inline Markdown → AnnotatedString (bold, italic, strikethrough, code, links). */
fun inlineAnnotated(inlines: List<MdInline>, styles: MarkdownStyles): AnnotatedString = buildAnnotatedString {
    fun emit(nodes: List<MdInline>) {
        for (node in nodes) {
            when (node) {
                is MdInline.Text -> append(node.text)
                is MdInline.Bold -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { emit(node.children) }
                is MdInline.Italic -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { emit(node.children) }
                is MdInline.Strike -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { emit(node.children) }
                is MdInline.Code -> withStyle(styles.code) { append(node.text) }
                is MdInline.Link -> {
                    val safe = node.url.startsWith("https://") || node.url.startsWith("http://")
                    if (safe) {
                        withLink(LinkAnnotation.Url(node.url, TextLinkStyles(styles.link))) { emit(node.children) }
                    } else {
                        emit(node.children)
                    }
                }
            }
        }
    }
    emit(inlines)
}

/** Renders an assistant reply. Parsing is remembered per text, so a streaming reply reparses only when it grows. */
@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier, color: Color = CrokTheme.colors.textPrimary) {
    val colors = CrokTheme.colors
    val blocks = remember(text) { Markdown.parse(text) }
    val styles = MarkdownStyles(
        code = SpanStyle(fontFamily = Mono, fontSize = 14.sp, background = colors.inlineCode),
        link = SpanStyle(color = colors.link, textDecoration = TextDecoration.Underline),
    )
    val body = MaterialTheme.typography.bodyLarge.copy(color = color)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (block in blocks) {
            when (block) {
                is MdBlock.Paragraph -> Text(inlineAnnotated(block.inlines, styles), style = body)
                is MdBlock.Heading -> Text(
                    inlineAnnotated(block.inlines, styles),
                    style = body.copy(
                        fontWeight = FontWeight.SemiBold,
                        fontSize = when (block.level) {
                            1 -> 20.sp
                            2 -> 18.sp
                            else -> 16.sp
                        },
                    ),
                )
                is MdBlock.Code -> CodeBlock(block.text)
                is MdBlock.ListItem -> Row(Modifier.padding(start = (block.depth * 16).dp)) {
                    Text(block.marker, style = body, color = colors.textSecondary, modifier = Modifier.width(if (block.ordered) 26.dp else 16.dp))
                    Text(inlineAnnotated(block.inlines, styles), style = body)
                }
                is MdBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
                    Box(Modifier.width(3.dp).fillMaxHeight().background(colors.accent.copy(alpha = 0.6f)))
                    Text(
                        inlineAnnotated(block.inlines, styles),
                        style = body.copy(color = colors.textSecondary),
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
                MdBlock.Rule -> HorizontalDivider(color = colors.divider)
            }
        }
    }
}

/** Monospaced, horizontally scrollable code (fenced blocks, tool output). */
@Composable
fun CodeBlock(text: String, modifier: Modifier = Modifier, style: TextStyle = CrokTheme.codeStyle) {
    val colors = CrokTheme.colors
    Box(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.codeBackground)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Text(text.trimEnd('\n'), style = style.copy(color = colors.textPrimary), softWrap = false)
    }
}
