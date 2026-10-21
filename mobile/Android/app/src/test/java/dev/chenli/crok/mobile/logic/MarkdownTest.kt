package dev.chenli.crok.mobile.logic

import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import dev.chenli.crok.mobile.ui.session.MarkdownStyles
import dev.chenli.crok.mobile.ui.session.inlineAnnotated
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownTest {
    private fun text(value: String) = MdInline.Text(value)
    private fun paragraph(vararg inlines: MdInline) = MdBlock.Paragraph(inlines.toList())

    @Test
    fun blocks() {
        val blocks = Markdown.parse(
            """
            # Title
            First line
            second line

            3. three
            4. four
               - nested
            > quoted
            >
            > > deeper

            ---
            ```rust
            fn main() {}
            ```

                indented code
            """.trimIndent(),
        )
        assertEquals(
            listOf(
                MdBlock.Heading(1, listOf(text("Title"))),
                paragraph(text("First line\nsecond line")),
                MdBlock.ListBlock(
                    ordered = true,
                    start = 3,
                    tight = true,
                    items = listOf(
                        MdListItem(null, listOf(paragraph(text("three")))),
                        MdListItem(
                            null,
                            listOf(
                                paragraph(text("four")),
                                MdBlock.ListBlock(false, 1, true, listOf(MdListItem(null, listOf(paragraph(text("nested")))))),
                            ),
                        ),
                    ),
                ),
                MdBlock.Quote(listOf(paragraph(text("quoted")), MdBlock.Quote(listOf(paragraph(text("deeper")))))),
                MdBlock.Rule,
                MdBlock.Code("rust", "fn main() {}"),
                MdBlock.Code(null, "indented code"),
            ),
            blocks,
        )
    }

    @Test
    fun taskListsAndTables() {
        val blocks = Markdown.parse("- [x] done\n- [ ] todo\n\n| a | b |\n|:--|--:|\n| **1** | x<br>y |\n| short |")
        assertEquals(
            MdBlock.ListBlock(false, 1, true, listOf(MdListItem(true, listOf(paragraph(text("done")))), MdListItem(false, listOf(paragraph(text("todo")))))),
            blocks[0],
        )
        assertEquals(
            MdBlock.Table(
                alignments = listOf(MdAlign.Start, MdAlign.End),
                header = listOf(listOf(text("a")), listOf(text("b"))),
                rows = listOf(
                    listOf(listOf(MdInline.Bold(listOf(text("1")))), listOf(text("x\ny"))),
                    listOf(listOf(text("short")), emptyList()),
                ),
            ),
            blocks[1],
        )
    }

    @Test
    fun mathInTextQuotesAndTables() {
        val blocks = Markdown.parse("Euler \$e^{i\\pi}\$ and\n\$\$\nx^2\n\$\$\nafter\n\n> \$\$\n> a\n> \$\$\n\n| \$a|b\$ | c |\n|---|---|")
        assertEquals(paragraph(text("Euler "), MdInline.Math("e^{i\\pi}", "\$e^{i\\pi}\$"), text(" and")), blocks[0])
        assertEquals(MdBlock.Math("x^2", "\$\$\nx^2\n\$\$"), blocks[1])
        assertEquals(paragraph(text("after")), blocks[2])
        assertEquals(MdBlock.Quote(listOf(MdBlock.Math("a", "\$\$\n> a\n> \$\$"))), blocks[3])
        assertEquals(listOf(MdInline.Math("a|b", "\$a|b\$")), (blocks[4] as MdBlock.Table).header[0])
    }

    @Test
    fun mathSourceComesBackWhereMathCannotRender() {
        // A dollar span inside a link URL (the scanner sees no code there) goes back to its source.
        assertEquals(
            listOf(MdInline.Link(listOf(text("pay")), "https://x.dev/\$a\$")),
            Markdown.parseInline("[pay](https://x.dev/\$a\$)"),
        )
        assertEquals(listOf(text("price \$5, see "), MdInline.Code("\$x\$")), Markdown.parseInline("price \$5, see `\$x\$`"))
        assertEquals(listOf(text("\$5 and \$6")), Markdown.parseInline("\\\$5 and \\\$6"))
    }

    @Test
    fun streamingTextRendersSensibly() {
        assertEquals(MdBlock.Code(null, "line 1\nline 2"), Markdown.parse("Look:\n```\nline 1\nline 2").last())
        assertEquals(listOf(paragraph(text("Then:\n\$\$\n\\frac{a}{"))), Markdown.parse("Then:\n\$\$\n\\frac{a}{"))
        assertEquals(listOf(text("a **half")), Markdown.parseInline("a **half"))
    }

    @Test
    fun inlines() {
        val inlines = Markdown.parseInline("a **bold** and *it* `code` ~~gone~~ [link](https://x.dev) https://y.dev.")
        assertEquals(
            listOf(
                text("a "),
                MdInline.Bold(listOf(text("bold"))),
                text(" and "),
                MdInline.Italic(listOf(text("it"))),
                text(" "),
                MdInline.Code("code"),
                text(" "),
                MdInline.Strike(listOf(text("gone"))),
                text(" "),
                MdInline.Link(listOf(text("link")), "https://x.dev"),
                text(" "),
                MdInline.Link(listOf(text("https://y.dev")), "https://y.dev"),
                text("."),
            ),
            inlines,
        )
    }

    @Test
    fun onlyWebAndMailLinksOpenAndImagesAreNeverFetched() {
        assertEquals(listOf(text("main.rs")), Markdown.parseInline("[main.rs](src/main.rs)"))
        assertEquals(listOf(text("js")), Markdown.parseInline("[js](javascript:alert(1))"))
        assertEquals(listOf(MdInline.Link(listOf(text("me@x.dev")), "mailto:me@x.dev")), Markdown.parseInline("me@x.dev"))
        assertEquals(
            listOf(MdInline.Link(listOf(text("🖼 Logo")), "https://x.dev/a.png"), text(" 🖼 b.png")),
            Markdown.parseInline("![Logo](https://x.dev/a.png) ![](b.png)"),
        )
    }

    @Test
    fun rawHtmlStaysText() {
        assertEquals(listOf(text("Raw <div class=\"x\">not a div</div>")), Markdown.parseInline("Raw <div class=\"x\">not a div</div>"))
        assertEquals(listOf(text("a\nb\nc")), Markdown.parseInline("a<br>b<BR />c"))
        assertEquals(listOf(paragraph(text("<div>\nblock\n</div>"))), Markdown.parse("<div>\nblock\n</div>"))
    }

    @Test
    fun leavesPlainTextAlone() {
        assertEquals(listOf(text("snake_case_name and 2 * 3 * 4")), Markdown.parseInline("snake_case_name and 2 * 3 * 4"))
        assertEquals(listOf(text("not *a link")), Markdown.parseInline("not *a link"))
        assertEquals(listOf(text("*stars*")), Markdown.parseInline("\\*stars\\*"))
    }

    @Test
    fun rendersToAnnotatedString() {
        val styles = MarkdownStyles(code = SpanStyle(fontFamily = FontFamily.Monospace), link = SpanStyle())
        val text = inlineAnnotated(Markdown.parseInline("**b** *i* `c` [l](https://x.dev) [js](javascript:alert) \$x^2\$"), styles)
        // Without a math renderer, a formula shows its source (held on one line by word joiners).
        assertEquals("b i c l js \$x^2\$", text.text.replace("⁠", ""))
        val spans = text.spanStyles.map { it.item to text.text.substring(it.start, it.end) }
        assertTrue(spans.contains(SpanStyle(fontWeight = FontWeight.SemiBold) to "b"))
        assertTrue(spans.contains(SpanStyle(fontStyle = FontStyle.Italic) to "i"))
        assertTrue(spans.contains(SpanStyle(fontFamily = FontFamily.Monospace) to "c"))
        val links = text.getLinkAnnotations(0, text.length)
        // Only http(s) links become clickable.
        assertEquals(1, links.size)
        assertEquals("https://x.dev", (links.single().item as LinkAnnotation.Url).url)
        // With one, the formula becomes inline content.
        val drawn = inlineAnnotated(Markdown.parseInline("a \$x\$"), styles) { "m0" }
        assertEquals(1, drawn.getStringAnnotations(0, drawn.length).size)
    }
}
