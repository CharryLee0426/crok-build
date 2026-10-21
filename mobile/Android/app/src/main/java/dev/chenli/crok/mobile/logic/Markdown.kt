package dev.chenli.crok.mobile.logic

import org.commonmark.ext.autolink.AutolinkExtension
import org.commonmark.ext.gfm.strikethrough.Strikethrough
import org.commonmark.ext.gfm.strikethrough.StrikethroughExtension
import org.commonmark.ext.gfm.tables.TableBlock
import org.commonmark.ext.gfm.tables.TableCell
import org.commonmark.ext.gfm.tables.TableRow
import org.commonmark.ext.gfm.tables.TablesExtension
import org.commonmark.ext.task.list.items.TaskListItemMarker
import org.commonmark.ext.task.list.items.TaskListItemsExtension
import org.commonmark.node.BlockQuote
import org.commonmark.node.BulletList
import org.commonmark.node.Code
import org.commonmark.node.Emphasis
import org.commonmark.node.FencedCodeBlock
import org.commonmark.node.HardLineBreak
import org.commonmark.node.Heading
import org.commonmark.node.HtmlBlock
import org.commonmark.node.HtmlInline
import org.commonmark.node.Image
import org.commonmark.node.IndentedCodeBlock
import org.commonmark.node.Link
import org.commonmark.node.ListBlock
import org.commonmark.node.ListItem
import org.commonmark.node.Node
import org.commonmark.node.OrderedList
import org.commonmark.node.Paragraph
import org.commonmark.node.SoftLineBreak
import org.commonmark.node.StrongEmphasis
import org.commonmark.node.Text
import org.commonmark.node.ThematicBreak
import org.commonmark.parser.Parser

/**
 * An assistant reply as the app renders it (relay/DESIGN.md §5 "Replies in Markdown"): CommonMark + GFM parsed by
 * commonmark-java, with math found first by [MathExtractor]. Links keep only URLs that may open (http, https, mailto);
 * images become links that are never fetched; raw HTML stays literal text except `<br>`.
 */
sealed interface MdBlock {
    data class Paragraph(val inlines: List<MdInline>) : MdBlock
    data class Heading(val level: Int, val inlines: List<MdInline>) : MdBlock
    data class Code(val language: String?, val text: String) : MdBlock
    data class ListBlock(val ordered: Boolean, val start: Int, val tight: Boolean, val items: List<MdListItem>) : MdBlock
    data class Quote(val blocks: List<MdBlock>) : MdBlock
    data object Rule : MdBlock
    data class Table(val alignments: List<MdAlign>, val header: List<List<MdInline>>, val rows: List<List<List<MdInline>>>) : MdBlock
    /** Display math on its own line. */
    data class Math(val tex: String, val source: String) : MdBlock
}

/** A list item; [checked] is null for an ordinary item, true / false for a task item. */
data class MdListItem(val checked: Boolean?, val blocks: List<MdBlock>)

enum class MdAlign { Start, Center, End }

sealed interface MdInline {
    data class Text(val text: String) : MdInline
    data class Bold(val children: List<MdInline>) : MdInline
    data class Italic(val children: List<MdInline>) : MdInline
    data class Strike(val children: List<MdInline>) : MdInline
    data class Code(val text: String) : MdInline
    data class Link(val children: List<MdInline>, val url: String) : MdInline
    /** Math in the text; [display] when it was written as display math but sits inside other inline markup. */
    data class Math(val tex: String, val source: String, val display: Boolean = false) : MdInline
}

object Markdown {
    private val parser: Parser = Parser.builder()
        .extensions(
            listOf(
                TablesExtension.create(),
                StrikethroughExtension.create(),
                TaskListItemsExtension.create(),
                AutolinkExtension.create(),
            ),
        )
        .build()

    private val BREAK_TAG = Regex("^<br\\s*/?>$", RegexOption.IGNORE_CASE)
    private val BREAK_TAGS = Regex("<br\\s*/?>", RegexOption.IGNORE_CASE)

    fun parse(text: String): List<MdBlock> {
        val math = MathExtractor.extract(text)
        return Converter(math).blocks(parser.parse(math.text))
    }

    /** Inline Markdown of one line (what a table cell or heading holds). */
    fun parseInline(text: String): List<MdInline> =
        when (val block = parse(text).singleOrNull()) {
            is MdBlock.Paragraph -> block.inlines
            is MdBlock.Heading -> block.inlines
            null -> emptyList()
            else -> listOf(MdInline.Text(text))
        }

    /** Whether a link may open: only the web and mail, never paths or schemes that run something. */
    fun isOpenable(url: String): Boolean {
        val lower = url.trim().lowercase()
        return lower.startsWith("https://") || lower.startsWith("http://") || lower.startsWith("mailto:")
    }

    /** Plain text of inlines, for previews and accessibility. */
    fun plain(inlines: List<MdInline>): String = buildString {
        for (inline in inlines) {
            when (inline) {
                is MdInline.Text -> append(inline.text)
                is MdInline.Code -> append(inline.text)
                is MdInline.Bold -> append(plain(inline.children))
                is MdInline.Italic -> append(plain(inline.children))
                is MdInline.Strike -> append(plain(inline.children))
                is MdInline.Link -> append(plain(inline.children))
                is MdInline.Math -> append(inline.tex)
            }
        }
    }

    private class Converter(private val math: MathExtraction) {
        fun blocks(parent: Node): List<MdBlock> {
            val out = ArrayList<MdBlock>()
            var node = parent.firstChild
            while (node != null) {
                block(node, out)
                node = node.next
            }
            return out
        }

        private fun block(node: Node, out: MutableList<MdBlock>) {
            when (node) {
                is Paragraph -> paragraph(inlines(node), out)
                is Heading -> out += MdBlock.Heading(node.level.coerceIn(1, 6), inlines(node))
                is FencedCodeBlock -> out += MdBlock.Code(
                    node.info?.trim()?.split(' ', '\t')?.firstOrNull()?.takeIf { it.isNotEmpty() }?.let(math::restore),
                    math.restore(node.literal.orEmpty()).removeSuffix("\n"),
                )
                is IndentedCodeBlock -> out += MdBlock.Code(null, math.restore(node.literal.orEmpty()).removeSuffix("\n"))
                is ListBlock -> out += MdBlock.ListBlock(
                    ordered = node is OrderedList,
                    start = (node as? OrderedList)?.markerStartNumber ?: 1,
                    tight = node.isTight,
                    items = generateSequence(node.firstChild) { it.next }.filterIsInstance<ListItem>().map(::listItem).toList(),
                )
                is BlockQuote -> out += MdBlock.Quote(blocks(node))
                is ThematicBreak -> out += MdBlock.Rule
                is HtmlBlock -> {
                    val literal = math.restore(node.literal.orEmpty()).trimEnd('\n')
                    out += MdBlock.Paragraph(merge(listOf(MdInline.Text(literal.replace(BREAK_TAGS, "\n")))))
                }
                is TableBlock -> out += table(node)
                else -> out += blocks(node)
            }
        }

        /** A paragraph, split where a display formula sits on its own line. */
        private fun paragraph(inlines: List<MdInline>, out: MutableList<MdBlock>) {
            var run = ArrayList<MdInline>()
            fun flush() {
                val trimmed = trimBreaks(run)
                if (trimmed.isNotEmpty()) out += MdBlock.Paragraph(trimmed)
                run = ArrayList()
            }
            for (inline in inlines) {
                if (inline is MdInline.Math && inline.display) {
                    flush()
                    out += MdBlock.Math(inline.tex, inline.source)
                } else {
                    run += inline
                }
            }
            flush()
        }

        private fun listItem(item: ListItem): MdListItem {
            var checked: Boolean? = null
            val marker = generateSequence(item.firstChild) { it.next }.filterIsInstance<TaskListItemMarker>().firstOrNull()
                ?: (item.firstChild as? Paragraph)?.firstChild as? TaskListItemMarker
            if (marker != null) {
                checked = marker.isChecked
                marker.unlink()
            }
            return MdListItem(checked, blocks(item))
        }

        private fun table(node: TableBlock): MdBlock.Table {
            val rows = ArrayList<TableRow>()
            fun collect(parent: Node) {
                var child = parent.firstChild
                while (child != null) {
                    if (child is TableRow) rows += child else collect(child)
                    child = child.next
                }
            }
            collect(node)
            val cells = rows.map { row -> generateSequence(row.firstChild) { it.next }.filterIsInstance<TableCell>().toList() }
            val headerCells = cells.firstOrNull().orEmpty()
            val columns = headerCells.size.coerceAtLeast(1)
            val alignments = (0 until columns).map { index ->
                when (headerCells.getOrNull(index)?.alignment) {
                    TableCell.Alignment.CENTER -> MdAlign.Center
                    TableCell.Alignment.RIGHT -> MdAlign.End
                    else -> MdAlign.Start
                }
            }
            fun row(row: List<TableCell>) = (0 until columns).map { index -> row.getOrNull(index)?.let(::inlines).orEmpty() }
            return MdBlock.Table(alignments, row(headerCells), cells.drop(1).map(::row))
        }

        fun inlines(parent: Node): List<MdInline> {
            val out = ArrayList<MdInline>()
            var node = parent.firstChild
            while (node != null) {
                inline(node, out)
                node = node.next
            }
            return merge(out)
        }

        private fun inline(node: Node, out: MutableList<MdInline>) {
            when (node) {
                is Text -> text(node.literal.orEmpty(), out)
                is StrongEmphasis -> out += MdInline.Bold(nested(node))
                is Emphasis -> out += MdInline.Italic(nested(node))
                is Strikethrough -> out += MdInline.Strike(nested(node))
                is Code -> out += MdInline.Code(math.restore(node.literal.orEmpty()))
                is Link -> {
                    val url = math.restore(node.destination.orEmpty())
                    val children = nested(node)
                    if (isOpenable(url)) out += MdInline.Link(children, url.trim()) else out += children
                }
                is Image -> {
                    val url = math.restore(node.destination.orEmpty())
                    val alt = plain(nested(node)).trim()
                    val label = MdInline.Text("🖼 " + alt.ifEmpty { url })
                    out += if (isOpenable(url)) MdInline.Link(listOf(label), url.trim()) else label
                }
                is SoftLineBreak, is HardLineBreak -> out += MdInline.Text("\n")
                is HtmlInline -> {
                    val literal = math.restore(node.literal.orEmpty())
                    out += MdInline.Text(if (BREAK_TAG.matches(literal.trim())) "\n" else literal)
                }
                is TaskListItemMarker -> Unit
                else -> {
                    var child = node.firstChild
                    while (child != null) {
                        inline(child, out)
                        child = child.next
                    }
                }
            }
        }

        /** Inline children of emphasis or a link; only a paragraph's own display formulas become blocks. */
        private fun nested(node: Node): List<MdInline> = inlines(node)

        private fun text(literal: String, out: MutableList<MdInline>) {
            for (piece in math.split(literal)) {
                when (piece) {
                    is String -> out += MdInline.Text(piece)
                    is MathSpan -> out += MdInline.Math(piece.tex, piece.source, piece.display)
                }
            }
        }

        private fun merge(inlines: List<MdInline>): List<MdInline> {
            val out = ArrayList<MdInline>(inlines.size)
            for (inline in inlines) {
                val last = out.lastOrNull()
                if (inline is MdInline.Text && inline.text.isEmpty()) continue
                if (inline is MdInline.Text && last is MdInline.Text) out[out.size - 1] = MdInline.Text(last.text + inline.text) else out += inline
            }
            return out
        }

        /** Drops the line breaks a display formula leaves at the edges of the text around it. */
        private fun trimBreaks(inlines: List<MdInline>): List<MdInline> {
            val out = merge(inlines).toMutableList()
            (out.firstOrNull() as? MdInline.Text)?.let { first ->
                val text = first.text.trimStart('\n')
                if (text.isEmpty()) out.removeAt(0) else out[0] = MdInline.Text(text)
            }
            (out.lastOrNull() as? MdInline.Text)?.let { last ->
                val text = last.text.trimEnd('\n')
                if (text.isEmpty()) out.removeAt(out.size - 1) else out[out.size - 1] = MdInline.Text(text)
            }
            return if (out.all { it is MdInline.Text && it.text.isBlank() }) emptyList() else out
        }
    }
}
