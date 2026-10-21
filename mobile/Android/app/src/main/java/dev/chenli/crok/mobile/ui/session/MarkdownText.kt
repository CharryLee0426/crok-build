package dev.chenli.crok.mobile.ui.session

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.CodeToken
import dev.chenli.crok.mobile.logic.Markdown
import dev.chenli.crok.mobile.logic.MdAlign
import dev.chenli.crok.mobile.logic.MdBlock
import dev.chenli.crok.mobile.logic.MdInline
import dev.chenli.crok.mobile.logic.SyntaxHighlighter
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.theme.CrokColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.Mono
import dev.chenli.crok.mobile.ui.theme.SyntaxColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** The span styles inline Markdown maps to; built from the theme in the app, plain values in tests. */
data class MarkdownStyles(
    val code: SpanStyle,
    val link: SpanStyle,
    /** TeX that cannot be drawn: its source, monospaced and muted. */
    val mathSource: SpanStyle = code,
)

/**
 * Inline Markdown → AnnotatedString (bold, italic, strikethrough, code, links, math). [math] returns the inline-content
 * id of a formula it can draw, or null to show the formula's source instead.
 */
fun inlineAnnotated(
    inlines: List<MdInline>,
    styles: MarkdownStyles,
    math: (MdInline.Math) -> String? = { null },
): AnnotatedString = buildAnnotatedString {
    fun emit(nodes: List<MdInline>) {
        for (node in nodes) {
            when (node) {
                is MdInline.Text -> append(node.text)
                is MdInline.Bold -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { emit(node.children) }
                is MdInline.Italic -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { emit(node.children) }
                is MdInline.Strike -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { emit(node.children) }
                is MdInline.Code -> withStyle(styles.code) { append(node.text) }
                is MdInline.Link -> withLink(LinkAnnotation.Url(node.url, TextLinkStyles(styles.link))) { emit(node.children) }
                is MdInline.Math -> {
                    val id = math(node)
                    if (id != null) appendInlineContent(id, node.tex) else withStyle(styles.mathSource) { append(unbroken(node.source)) }
                }
            }
        }
    }
    emit(inlines)
}

/** A short formula's source kept on one line (word joiners between its characters), so `$` never ends a line alone. */
private fun unbroken(source: String): String =
    if (source.length > 32) source else source.toList().joinToString("⁠")

/** Fenced code → AnnotatedString in the highlight colours; plain when the language is unknown or missing. */
fun highlightedCode(code: String, language: String?, syntax: SyntaxColors): AnnotatedString {
    val spans = SyntaxHighlighter.highlight(code, language)
    if (spans.isEmpty()) return AnnotatedString(code)
    val builder = AnnotatedString.Builder(code)
    for (span in spans) builder.addStyle(syntaxStyle(span.token, syntax), span.start, span.end)
    return builder.toAnnotatedString()
}

private fun syntaxStyle(token: CodeToken, syntax: SyntaxColors): SpanStyle = when (token) {
    CodeToken.Comment -> SpanStyle(color = syntax.comment, fontStyle = FontStyle.Italic)
    CodeToken.Keyword, CodeToken.Meta -> SpanStyle(color = syntax.keyword)
    CodeToken.Str, CodeToken.Regex -> SpanStyle(color = syntax.string)
    CodeToken.Number, CodeToken.Literal, CodeToken.Property, CodeToken.Variable -> SpanStyle(color = syntax.number)
    CodeToken.Function, CodeToken.Section -> SpanStyle(color = syntax.function)
    CodeToken.Type, CodeToken.Builtin -> SpanStyle(color = syntax.type)
    CodeToken.Tag -> SpanStyle(color = syntax.tag)
    CodeToken.Inserted -> SpanStyle(color = syntax.inserted, background = syntax.insertedBackground)
    CodeToken.Deleted -> SpanStyle(color = syntax.deleted, background = syntax.deletedBackground)
}

/** Everything a reply's blocks are drawn with. */
private data class MdStyle(
    val colors: CrokColors,
    val color: Color,
    val body: TextStyle,
    val styles: MarkdownStyles,
    val density: Density,
    val context: Context,
    /** Inline math wider than this (60 % of the screen) is shown as a display block. */
    val maxInlineMathPx: Float,
    /** [MathImages.ready]: part of the style so remembered text is rebuilt once formulas can be drawn. */
    val mathReady: Boolean,
    val onCopyCode: (String) -> Unit,
)

private val BULLETS = listOf("•", "◦", "▪")
private val TABLE_COLUMN_CAP = 260.dp
private val TABLE_COLUMN_MIN = 36.dp

/**
 * Renders an assistant reply (relay/DESIGN.md §5 "Replies in Markdown"). Parsing is remembered per text, so a streaming
 * reply reparses only when it grows; code highlighting and math bitmaps are cached. Wide code, tables and display math
 * scroll sideways inside the bubble.
 */
@Composable
fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = CrokTheme.colors.textPrimary,
    onCopyCode: (String) -> Unit = {},
) {
    val colors = CrokTheme.colors
    val blocks = remember(text) { Markdown.parse(text) }
    val density = LocalDensity.current
    val context = LocalContext.current
    // The window's width; unknown (0) for a moment at start, when no formula is lifted out.
    val windowWidthPx = LocalWindowInfo.current.containerSize.width.takeIf { it > 0 } ?: Int.MAX_VALUE
    val body = MaterialTheme.typography.bodyLarge.copy(color = color)
    val mathReady = MathImages.ready
    if (!mathReady && ('$' in text || "\\(" in text || "\\[" in text)) {
        // JLatexMath's start-up is too slow for the main thread; formulas show their source until it is done.
        val appContext = context.applicationContext ?: context
        LaunchedEffect(Unit) { withContext(Dispatchers.Default) { MathImages.warmUp(appContext) } }
    }
    val md = MdStyle(
        colors = colors,
        color = color,
        body = body,
        styles = MarkdownStyles(
            code = SpanStyle(fontFamily = Mono, fontSize = 14.sp, background = colors.inlineCode),
            link = SpanStyle(color = colors.link, textDecoration = TextDecoration.Underline),
            mathSource = SpanStyle(fontFamily = Mono, fontSize = 14.sp, color = colors.textSecondary),
        ),
        density = density,
        context = context,
        maxInlineMathPx = windowWidthPx * 0.6f,
        mathReady = mathReady,
        onCopyCode = onCopyCode,
    )
    MdBlocks(blocks, md, modifier)
}

@Composable
private fun MdBlocks(blocks: List<MdBlock>, md: MdStyle, modifier: Modifier = Modifier, spacing: Dp = 8.dp, depth: Int = 0) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(spacing)) {
        for (block in blocks) MdBlockView(block, md, depth)
    }
}

@Composable
private fun MdBlockView(block: MdBlock, md: MdStyle, depth: Int) {
    when (block) {
        is MdBlock.Paragraph -> MdParagraph(block.inlines, md)
        is MdBlock.Heading -> MdInlineText(block.inlines, md, headingStyle(block.level, md))
        is MdBlock.Code -> FencedCode(block.language, block.text, md)
        is MdBlock.ListBlock -> MdList(block, md, depth)
        is MdBlock.Quote -> {
            val bar = md.colors.accent.copy(alpha = 0.6f)
            val quoted = md.copy(color = md.colors.textSecondary, body = md.body.copy(color = md.colors.textSecondary))
            MdBlocks(
                block.blocks,
                quoted,
                Modifier
                    .drawBehind { drawRect(bar, size = Size(3.dp.toPx(), size.height)) }
                    .padding(start = 13.dp),
                depth = depth,
            )
        }
        MdBlock.Rule -> HorizontalDivider(Modifier.padding(vertical = 4.dp), color = md.colors.divider)
        is MdBlock.Table -> MdTable(block, md)
        is MdBlock.Math -> DisplayMath(block.tex, block.source, md)
    }
}

private fun headingStyle(level: Int, md: MdStyle): TextStyle {
    val size = when (level) {
        1 -> 21.sp
        2 -> 19.sp
        3 -> 17.sp
        4 -> 16.sp
        5 -> 15.sp
        else -> 14.sp
    }
    return md.body.copy(
        fontWeight = FontWeight.SemiBold,
        fontSize = size,
        lineHeight = size * 1.3f,
        color = if (level == 6) md.colors.textSecondary else md.color,
    )
}

/** A paragraph; an inline formula too wide for the line is lifted out as a display block. */
@Composable
private fun MdParagraph(inlines: List<MdInline>, md: MdStyle) {
    val sizePx = with(md.density) { md.body.fontSize.toPx() }
    val segments = remember(inlines, md.maxInlineMathPx, sizePx, md.mathReady) {
        val out = ArrayList<Any>()
        var run = ArrayList<MdInline>()
        for (inline in inlines) {
            val wide = inline is MdInline.Math &&
                (MathImages.render(md.context, inline.tex, display = false, sizePx)?.width ?: 0) > md.maxInlineMathPx
            if (wide) {
                // The text around a lifted formula loses the spaces that separated them.
                (run.lastOrNull() as? MdInline.Text)?.let { run[run.size - 1] = MdInline.Text(it.text.trimEnd()) }
                if (run.isNotEmpty()) out.add(run)
                run = ArrayList()
                out.add(MdBlock.Math((inline as MdInline.Math).tex, inline.source))
            } else {
                if (run.isEmpty() && out.lastOrNull() is MdBlock.Math && inline is MdInline.Text) {
                    run.add(MdInline.Text(inline.text.trimStart()))
                } else {
                    run.add(inline)
                }
            }
        }
        if (run.isNotEmpty()) out.add(run)
        out
    }
    if (segments.size == 1 && segments[0] is List<*>) {
        MdInlineText(inlines, md, md.body)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (segment in segments) {
            @Suppress("UNCHECKED_CAST")
            when (segment) {
                is MdBlock.Math -> DisplayMath(segment.tex, segment.source, md)
                else -> MdInlineText(segment as List<MdInline>, md, md.body)
            }
        }
    }
}

private class BuiltInline(val text: AnnotatedString, val content: Map<String, InlineTextContent>)

@Composable
private fun MdInlineText(inlines: List<MdInline>, md: MdStyle, style: TextStyle, modifier: Modifier = Modifier) {
    val built = remember(inlines, md, style) { buildInline(inlines, md, style) }
    Text(built.text, modifier, style = style, inlineContent = built.content)
}

private fun buildInline(inlines: List<MdInline>, md: MdStyle, style: TextStyle): BuiltInline {
    val content = HashMap<String, InlineTextContent>()
    val sizePx = with(md.density) { style.fontSize.toPx() }
    val tint = style.color.takeIf { it != Color.Unspecified } ?: md.color
    val text = inlineAnnotated(inlines, md.styles) { math ->
        val rendered = MathImages.render(md.context, math.tex, display = false, sizePx) ?: return@inlineAnnotated null
        val id = "math${content.size}"
        val placeholder = with(md.density) {
            // Bottom on the baseline and as tall as the formula's ascent; the depth draws below it, like a descender.
            Placeholder(rendered.width.toSp(), rendered.ascent.coerceAtLeast(1).toSp(), PlaceholderVerticalAlign.AboveBaseline)
        }
        content[id] = InlineTextContent(placeholder) {
            Spacer(
                Modifier
                    .fillMaxSize()
                    .drawBehind { drawImage(rendered.image, colorFilter = ColorFilter.tint(tint)) },
            )
        }
        id
    }
    return BuiltInline(text, content)
}

/** Display math: centred when it fits, scrolling sideways when it does not; its source when it cannot be drawn. */
@Composable
private fun DisplayMath(tex: String, source: String, md: MdStyle) {
    val sizePx = with(md.density) { md.body.fontSize.toPx() } * 1.15f
    val rendered = remember(tex, sizePx, md.mathReady) { MathImages.render(md.context, tex, display = true, sizePx) }
    if (rendered == null) {
        Box(Modifier.horizontalScroll(rememberScrollState())) {
            Text(source, style = CrokTheme.codeStyle.copy(color = md.colors.textSecondary), softWrap = false)
        }
        return
    }
    val tint = md.color
    val (width, height) = with(md.density) { rendered.width.toDp() to rendered.height.toDp() }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 4.dp)) {
            Spacer(
                Modifier
                    .size(width, height)
                    .semantics { contentDescription = tex }
                    .drawBehind { drawImage(rendered.image, colorFilter = ColorFilter.tint(tint)) },
            )
        }
    }
}

@Composable
private fun MdList(list: MdBlock.ListBlock, md: MdStyle, depth: Int) {
    val spacing = if (list.tight) 2.dp else 6.dp
    val last = list.start + list.items.size - 1
    val markerWidth = when {
        list.items.any { it.checked != null } -> 24.dp
        list.ordered -> (12 + 9 * last.toString().length).dp
        else -> 16.dp
    }
    Column(verticalArrangement = Arrangement.spacedBy(spacing)) {
        list.items.forEachIndexed { index, item ->
            Row {
                val marker = when {
                    item.checked == true -> "☑"
                    item.checked == false -> "☐"
                    list.ordered -> "${list.start + index}."
                    else -> BULLETS[depth % BULLETS.size]
                }
                Text(
                    marker,
                    style = md.body,
                    color = if (item.checked == true) md.colors.accent else md.colors.textSecondary,
                    modifier = Modifier.width(markerWidth),
                )
                MdBlocks(item.blocks, md, Modifier.weight(1f, fill = false), spacing = spacing, depth = depth + 1)
            }
        }
    }
}

@Composable
private fun FencedCode(language: String?, code: String, md: MdStyle) {
    val colors = md.colors
    val highlighted = remember(code, language, colors.syntax) { highlightedCode(code, language, colors.syntax) }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.codeBackground),
    ) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                language.orEmpty(),
                color = colors.textSecondary,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            CopyCodeButton(code, md)
        }
        Box(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(start = 12.dp, end = 12.dp, bottom = 10.dp),
        ) {
            Text(highlighted, style = CrokTheme.codeStyle.copy(color = colors.textPrimary), softWrap = false)
        }
    }
}

@Composable
private fun CopyCodeButton(code: String, md: MdStyle) {
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_500)
            copied = false
        }
    }
    val tint = md.colors.textSecondary
    Row(
        Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable {
                md.onCopyCode(code)
                copied = true
            }
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (copied) CrokIcons.Check else CrokIcons.Copy, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(4.dp))
        Text(stringResource(if (copied) R.string.copied else R.string.action_copy), color = tint, fontSize = 12.sp)
    }
}

/** Where a table's rows and columns ended up, for drawing its grid. */
private class TableGrid {
    var columns: IntArray = IntArray(0)
    var rows: IntArray = IntArray(0)

    fun draw(scope: DrawScope, line: Color, header: Color) = with(scope) {
        if (rows.size < 2 || columns.isEmpty()) return
        drawRect(header, size = Size(size.width, rows[1].toFloat()))
        val stroke = 1f
        for (y in rows) {
            val top = y.toFloat().coerceAtMost(size.height - stroke)
            drawRect(line, topLeft = Offset(0f, top), size = Size(size.width, stroke))
        }
        for (x in columns) {
            val left = x.toFloat().coerceAtMost(size.width - stroke)
            drawRect(line, topLeft = Offset(left, 0f), size = Size(stroke, size.height))
        }
    }
}

/**
 * A GFM table: each column as wide as its widest cell up to [TABLE_COLUMN_CAP] (cells wrap beyond that), header bold
 * on a tinted row, hairline grid, the columns' alignment. Wider than the bubble, it scrolls sideways; narrower, it
 * keeps its own width.
 */
@Composable
private fun MdTable(table: MdBlock.Table, md: MdStyle) {
    val colors = md.colors
    val grid = remember { TableGrid() }
    val rows = remember(table) { listOf(table.header) + table.rows }
    val columns = table.alignments.size
    val header = md.body.copy(fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 20.sp)
    val cell = md.body.copy(fontSize = 15.sp, lineHeight = 20.sp)
    Box(Modifier.horizontalScroll(rememberScrollState())) {
        Layout(
            content = {
                rows.forEachIndexed { r, row ->
                    row.forEachIndexed { c, inlines ->
                        val align = when (table.alignments[c]) {
                            MdAlign.Start -> TextAlign.Start
                            MdAlign.Center -> TextAlign.Center
                            MdAlign.End -> TextAlign.End
                        }
                        MdInlineText(
                            inlines,
                            md,
                            (if (r == 0) header else cell).copy(textAlign = align),
                            Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
            },
            modifier = Modifier.drawBehind { grid.draw(this, colors.divider, colors.codeBackground) },
        ) { measurables, _ ->
            val cap = TABLE_COLUMN_CAP.roundToPx()
            val min = TABLE_COLUMN_MIN.roundToPx()
            val line = 1
            val widths = IntArray(columns) { c ->
                rows.indices.maxOf { r -> measurables[r * columns + c].maxIntrinsicWidth(Constraints.Infinity) }.coerceIn(min, cap)
            }
            val placeables = measurables.mapIndexed { index, measurable ->
                measurable.measure(Constraints.fixedWidth(widths[index % columns]))
            }
            val heights = IntArray(rows.size) { r -> (0 until columns).maxOf { c -> placeables[r * columns + c].height } }
            val xs = IntArray(columns + 1)
            for (c in 0 until columns) xs[c + 1] = xs[c] + line + widths[c]
            val ys = IntArray(rows.size + 1)
            for (r in rows.indices) ys[r + 1] = ys[r] + line + heights[r]
            val width = xs[columns] + line
            val height = ys[rows.size] + line
            grid.columns = xs
            grid.rows = ys
            layout(width, height) {
                placeables.forEachIndexed { index, placeable ->
                    val r = index / columns
                    val c = index % columns
                    placeable.place(xs[c] + line, ys[r] + line)
                }
            }
        }
    }
}

/** Monospaced, horizontally scrollable code (tool output). */
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
