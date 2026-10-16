package dev.chenli.crok.mobile.logic

/**
 * A small Markdown reader for assistant replies: paragraphs, headings, fenced code, lists, quotes, rules, and inline
 * bold / italic / strikethrough / code / links. Tolerant of half-streamed text: an unclosed fence runs to the end, an
 * unclosed `**` stays literal.
 */
sealed interface MdBlock {
    data class Paragraph(val inlines: List<MdInline>) : MdBlock
    data class Heading(val level: Int, val inlines: List<MdInline>) : MdBlock
    data class Code(val language: String?, val text: String) : MdBlock
    data class ListItem(val marker: String, val ordered: Boolean, val depth: Int, val inlines: List<MdInline>) : MdBlock
    data class Quote(val inlines: List<MdInline>) : MdBlock
    data object Rule : MdBlock
}

sealed interface MdInline {
    data class Text(val text: String) : MdInline
    data class Bold(val children: List<MdInline>) : MdInline
    data class Italic(val children: List<MdInline>) : MdInline
    data class Strike(val children: List<MdInline>) : MdInline
    data class Code(val text: String) : MdInline
    data class Link(val children: List<MdInline>, val url: String) : MdInline
}

object Markdown {
    private val headingRe = Regex("^(#{1,6})\\s+(.*)$")
    private val ruleRe = Regex("^\\s{0,3}([-*_])(\\s*\\1){2,}\\s*$")
    private val bulletRe = Regex("^(\\s*)([-*+])\\s+(.*)$")
    private val orderedRe = Regex("^(\\s*)(\\d{1,9})([.)])\\s+(.*)$")
    private val fenceRe = Regex("^\\s{0,3}(`{3,}|~{3,})\\s*([^`\\s]*).*$")

    fun parse(text: String): List<MdBlock> {
        val blocks = ArrayList<MdBlock>()
        val lines = text.replace("\r\n", "\n").split('\n')
        val paragraph = StringBuilder()
        val quote = StringBuilder()

        fun flushParagraph() {
            if (paragraph.isNotEmpty()) {
                blocks += MdBlock.Paragraph(parseInline(paragraph.toString().trimEnd()))
                paragraph.clear()
            }
        }

        fun flushQuote() {
            if (quote.isNotEmpty()) {
                blocks += MdBlock.Quote(parseInline(quote.toString().trimEnd()))
                quote.clear()
            }
        }

        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val fence = fenceRe.matchEntire(line)
            if (fence != null) {
                flushParagraph()
                flushQuote()
                val marker = fence.groupValues[1]
                val language = fence.groupValues[2].ifBlank { null }
                val body = ArrayList<String>()
                i++
                while (i < lines.size) {
                    val candidate = lines[i].trim()
                    if (candidate.startsWith(marker.take(3)) && candidate.trimStart(marker[0]).isBlank() &&
                        candidate.length >= marker.length
                    ) {
                        break
                    }
                    body += lines[i]
                    i++
                }
                blocks += MdBlock.Code(language, body.joinToString("\n"))
                i++ // skip the closing fence (or step past the end)
                continue
            }
            if (line.isBlank()) {
                flushParagraph()
                flushQuote()
                i++
                continue
            }
            if (line.trimStart().startsWith("|")) {
                // Tables read best monospaced on a phone.
                flushParagraph()
                flushQuote()
                val table = ArrayList<String>()
                while (i < lines.size && lines[i].trimStart().startsWith("|")) {
                    table += lines[i].trim()
                    i++
                }
                blocks += MdBlock.Code(null, table.joinToString("\n"))
                continue
            }
            val heading = headingRe.matchEntire(line.trimStart())
            if (heading != null && line.length - line.trimStart().length < 4) {
                flushParagraph()
                flushQuote()
                blocks += MdBlock.Heading(heading.groupValues[1].length, parseInline(heading.groupValues[2].trimEnd('#', ' ')))
                i++
                continue
            }
            if (ruleRe.matches(line)) {
                flushParagraph()
                flushQuote()
                blocks += MdBlock.Rule
                i++
                continue
            }
            val bullet = bulletRe.matchEntire(line)
            if (bullet != null) {
                flushParagraph()
                flushQuote()
                val depth = bullet.groupValues[1].replace("\t", "  ").length / 2
                blocks += MdBlock.ListItem("•", ordered = false, depth = depth, inlines = parseInline(taskBox(bullet.groupValues[3])))
                i++
                continue
            }
            val ordered = orderedRe.matchEntire(line)
            if (ordered != null) {
                flushParagraph()
                flushQuote()
                val depth = ordered.groupValues[1].replace("\t", "  ").length / 2
                blocks += MdBlock.ListItem(
                    marker = ordered.groupValues[2] + ".",
                    ordered = true,
                    depth = depth,
                    inlines = parseInline(ordered.groupValues[4]),
                )
                i++
                continue
            }
            if (line.trimStart().startsWith(">")) {
                flushParagraph()
                if (quote.isNotEmpty()) quote.append('\n')
                quote.append(line.trimStart().removePrefix(">").removePrefix(" "))
                i++
                continue
            }
            flushQuote()
            // A line continuing a list item belongs to it.
            val previous = blocks.lastOrNull()
            if (paragraph.isEmpty() && previous is MdBlock.ListItem && line.startsWith("  ")) {
                blocks[blocks.size - 1] = previous.copy(inlines = previous.inlines + MdInline.Text("\n") + parseInline(line.trim()))
                i++
                continue
            }
            if (paragraph.isNotEmpty()) paragraph.append('\n')
            paragraph.append(line.trimEnd())
            i++
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    private fun taskBox(text: String): String = when {
        text.startsWith("[ ] ") -> "☐ " + text.substring(4)
        text.startsWith("[x] ") || text.startsWith("[X] ") -> "☑ " + text.substring(4)
        else -> text
    }

    fun parseInline(text: String): List<MdInline> {
        val out = ArrayList<MdInline>()
        val buffer = StringBuilder()

        fun flush() {
            if (buffer.isNotEmpty()) {
                out += MdInline.Text(buffer.toString())
                buffer.clear()
            }
        }

        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                c == '\\' && i + 1 < text.length && text[i + 1] in ESCAPABLE -> {
                    buffer.append(text[i + 1])
                    i += 2
                }
                c == '`' -> {
                    var ticks = 0
                    while (i + ticks < text.length && text[i + ticks] == '`') ticks++
                    val fence = "`".repeat(ticks)
                    val end = text.indexOf(fence, i + ticks)
                    if (end < 0) {
                        buffer.append(fence)
                        i += ticks
                    } else {
                        flush()
                        out += MdInline.Code(text.substring(i + ticks, end).let { if (it.startsWith(" ") && it.endsWith(" ") && it.isNotBlank()) it.substring(1, it.length - 1) else it })
                        i = end + ticks
                    }
                }
                (c == '*' || c == '_') && text.startsWith("$c$c", i) -> {
                    val marker = "$c$c"
                    val end = findClosing(text, marker, i + 2)
                    if (end < 0 || (c == '_' && !wordBoundaryBefore(text, i))) {
                        buffer.append(marker)
                        i += 2
                    } else {
                        flush()
                        out += MdInline.Bold(parseInline(text.substring(i + 2, end)))
                        i = end + 2
                    }
                }
                c == '~' && text.startsWith("~~", i) -> {
                    val end = findClosing(text, "~~", i + 2)
                    if (end < 0) {
                        buffer.append("~~")
                        i += 2
                    } else {
                        flush()
                        out += MdInline.Strike(parseInline(text.substring(i + 2, end)))
                        i = end + 2
                    }
                }
                (c == '*' || c == '_') -> {
                    val opensWord = i + 1 < text.length && !text[i + 1].isWhitespace()
                    val end = if (opensWord && (c == '*' || wordBoundaryBefore(text, i))) findSingleClosing(text, c, i + 1) else -1
                    if (end < 0) {
                        buffer.append(c)
                        i++
                    } else {
                        flush()
                        out += MdInline.Italic(parseInline(text.substring(i + 1, end)))
                        i = end + 1
                    }
                }
                c == '[' -> {
                    val close = findBracketClose(text, i)
                    if (close > 0 && close + 1 < text.length && text[close + 1] == '(') {
                        val urlEnd = text.indexOf(')', close + 2)
                        if (urlEnd > 0) {
                            val url = text.substring(close + 2, urlEnd).trim().substringBefore(' ')
                            flush()
                            out += MdInline.Link(parseInline(text.substring(i + 1, close)), url)
                            i = urlEnd + 1
                            continue
                        }
                    }
                    buffer.append(c)
                    i++
                }
                (c == 'h') && wordBoundaryBefore(text, i) && (text.startsWith("https://", i) || text.startsWith("http://", i)) -> {
                    var end = i
                    while (end < text.length && !text[end].isWhitespace() && text[end] != '<' && text[end] != '>') end++
                    while (end > i && text[end - 1] in ".,;:!?)'\"") end--
                    val url = text.substring(i, end)
                    flush()
                    out += MdInline.Link(listOf(MdInline.Text(url)), url)
                    i = end
                }
                else -> {
                    buffer.append(c)
                    i++
                }
            }
        }
        flush()
        return out
    }

    private const val ESCAPABLE = "\\`*_{}[]()#+-.!|~>"

    private fun wordBoundaryBefore(text: String, index: Int): Boolean =
        index == 0 || !text[index - 1].isLetterOrDigit()

    private fun findClosing(text: String, marker: String, from: Int): Int {
        var index = text.indexOf(marker, from)
        while (index >= 0) {
            if (index > from && !text[index - 1].isWhitespace()) return index
            index = text.indexOf(marker, index + 1)
        }
        return -1
    }

    private fun findSingleClosing(text: String, marker: Char, from: Int): Int {
        var index = from
        while (index < text.length) {
            val ch = text[index]
            if (ch == '`') {
                val end = text.indexOf('`', index + 1)
                if (end < 0) return -1
                index = end + 1
                continue
            }
            if (ch == marker) {
                val doubled = index + 1 < text.length && text[index + 1] == marker
                if (doubled) {
                    index += 2
                    continue
                }
                val afterOk = marker == '*' || index + 1 >= text.length || !text[index + 1].isLetterOrDigit()
                if (index > from && !text[index - 1].isWhitespace() && afterOk) return index
            }
            if (ch == '\n') return -1
            index++
        }
        return -1
    }

    private fun findBracketClose(text: String, open: Int): Int {
        var depth = 0
        for (index in open until text.length) {
            when (text[index]) {
                '[' -> depth++
                ']' -> {
                    depth--
                    if (depth == 0) return index
                }
                '\n' -> return -1
            }
        }
        return -1
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
            }
        }
    }
}
