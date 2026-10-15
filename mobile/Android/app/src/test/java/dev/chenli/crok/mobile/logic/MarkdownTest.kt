package dev.chenli.crok.mobile.logic

import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import dev.chenli.crok.mobile.ui.session.MarkdownStyles
import dev.chenli.crok.mobile.ui.session.inlineAnnotated
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownTest {
    @Test
    fun blocks() {
        val blocks = Markdown.parse(
            """
            # Title
            First line
            second line

            - one
              continued
            - two
            1. first
            > quoted
            ---
            ```rust
            fn main() {}
            ```
            | a | b |
            | - | - |
            """.trimIndent(),
        )
        assertEquals(
            listOf(
                MdBlock.Heading::class,
                MdBlock.Paragraph::class,
                MdBlock.ListItem::class,
                MdBlock.ListItem::class,
                MdBlock.ListItem::class,
                MdBlock.Quote::class,
                MdBlock.Rule::class,
                MdBlock.Code::class,
                MdBlock.Code::class,
            ),
            blocks.map { it::class },
        )
        assertEquals("First line\nsecond line", Markdown.plain((blocks[1] as MdBlock.Paragraph).inlines))
        assertEquals("one\ncontinued", Markdown.plain((blocks[2] as MdBlock.ListItem).inlines))
        val ordered = blocks[4] as MdBlock.ListItem
        assertTrue(ordered.ordered)
        assertEquals("1.", ordered.marker)
        assertEquals(MdBlock.Code("rust", "fn main() {}"), blocks[7])
    }

    @Test
    fun unclosedFenceRunsToTheEndWhileStreaming() {
        val blocks = Markdown.parse("Look:\n```\nline 1\nline 2")
        assertEquals(MdBlock.Code(null, "line 1\nline 2"), blocks.last())
    }

    @Test
    fun inlines() {
        val inlines = Markdown.parseInline("a **bold** and *it* `code` ~~gone~~ [link](https://x.dev) https://y.dev.")
        assertEquals(
            listOf(
                MdInline.Text("a "),
                MdInline.Bold(listOf(MdInline.Text("bold"))),
                MdInline.Text(" and "),
                MdInline.Italic(listOf(MdInline.Text("it"))),
                MdInline.Text(" "),
                MdInline.Code("code"),
                MdInline.Text(" "),
                MdInline.Strike(listOf(MdInline.Text("gone"))),
                MdInline.Text(" "),
                MdInline.Link(listOf(MdInline.Text("link")), "https://x.dev"),
                MdInline.Text(" "),
                MdInline.Link(listOf(MdInline.Text("https://y.dev")), "https://y.dev"),
                MdInline.Text("."),
            ),
            inlines,
        )
    }

    @Test
    fun leavesHalfStreamedAndPlainTextAlone() {
        assertEquals(listOf(MdInline.Text("a **half")), Markdown.parseInline("a **half"))
        assertEquals(listOf(MdInline.Text("snake_case_name and 2 * 3 * 4")), Markdown.parseInline("snake_case_name and 2 * 3 * 4"))
        assertEquals(listOf(MdInline.Text("not *a link")), Markdown.parseInline("not *a link"))
        assertEquals(listOf(MdInline.Text("*stars*")), Markdown.parseInline("\\*stars\\*"))
    }

    @Test
    fun rendersToAnnotatedString() {
        val styles = MarkdownStyles(code = SpanStyle(fontFamily = FontFamily.Monospace), link = SpanStyle())
        val text = inlineAnnotated(Markdown.parseInline("**b** *i* `c` [l](https://x.dev) [js](javascript:alert)"), styles)
        assertEquals("b i c l js", text.text)
        val spans = text.spanStyles.map { it.item to text.text.substring(it.start, it.end) }
        assertTrue(spans.contains(SpanStyle(fontWeight = FontWeight.SemiBold) to "b"))
        assertTrue(spans.contains(SpanStyle(fontStyle = FontStyle.Italic) to "i"))
        assertTrue(spans.contains(SpanStyle(fontFamily = FontFamily.Monospace) to "c"))
        val links = text.getLinkAnnotations(0, text.length)
        // Only http(s) links become clickable.
        assertEquals(1, links.size)
        assertEquals("https://x.dev", (links.single().item as LinkAnnotation.Url).url)
    }
}
