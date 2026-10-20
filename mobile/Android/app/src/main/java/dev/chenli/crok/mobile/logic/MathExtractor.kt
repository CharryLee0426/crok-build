package dev.chenli.crok.mobile.logic

/** One math span found in a reply: its TeX, whether it is a display block, and the source with its delimiters. */
data class MathSpan(val tex: String, val display: Boolean, val source: String)

/** A reply with its math replaced by placeholders ([MathExtractor]), and the spans the placeholders stand for. */
class MathExtraction(val text: String, val spans: List<MathSpan>) {
    /** Puts the original source back wherever a placeholder landed somewhere math cannot render (code, URLs, HTML). */
    fun restore(value: String): String {
        if (spans.isEmpty() || value.none { it == MathExtractor.INLINE_OPEN || it == MathExtractor.DISPLAY_OPEN }) return value
        return MathExtractor.PLACEHOLDER.replace(value) { match ->
            spans.getOrNull(match.groupValues[2].toInt())?.source ?: match.value
        }
    }

    /** Splits text into literal pieces and the math spans of the placeholders in it. */
    fun split(value: String): List<Any> {
        if (spans.isEmpty()) return listOf(value)
        val out = ArrayList<Any>()
        var last = 0
        for (match in MathExtractor.PLACEHOLDER.findAll(value)) {
            val span = spans.getOrNull(match.groupValues[2].toInt()) ?: continue
            if (match.range.first > last) out += value.substring(last, match.range.first)
            out += span
            last = match.range.last + 1
        }
        if (last < value.length) out += value.substring(last)
        return out
    }
}

/**
 * Finds the math in a reply before it goes to the Markdown parser (relay/DESIGN.md §5 "Replies in Markdown", rules
 * 1–7), so `\(` keeps its backslash and `_` / `*` inside TeX never become emphasis. `$…$` and `\(…\)` are inline,
 * `$$…$$` and `\[…\]` display; code (fences and spans) is copied untouched; a single `$` follows the pandoc rule, so
 * dollars in prose about money or shells stay dollars. Each span becomes a placeholder the parser treats as a word.
 */
object MathExtractor {
    const val INLINE_OPEN = ''
    const val INLINE_CLOSE = ''
    const val DISPLAY_OPEN = ''
    const val DISPLAY_CLOSE = ''

    internal val PLACEHOLDER = Regex("([])(\\d+)[]")

    /** What may come before `$$` for it to start its line: spaces, quote markers, a list marker. */
    private val LINE_PREFIX = Regex("^[ \\t]*(?:>[ \\t]?)*[ \\t]*(?:(?:[-*+]|\\d{1,9}[.)])[ \\t]+)?$")
    private val LIST_MARKER = Regex("^(?:[-*+]|\\d{1,9}[.)])[ \\t]+")

    private class Fence(val marker: Char, val length: Int)

    fun extract(source: String): MathExtraction {
        val s = source.replace("\r\n", "\n").replace('\r', '\n')
        if (s.none { it == '$' || it == '\\' }) return MathExtraction(s, emptyList())
        val out = StringBuilder(s.length)
        val spans = ArrayList<MathSpan>()
        val n = s.length
        var i = 0
        var lineStart = true
        var fence: Fence? = null

        fun addSpan(start: Int, contentStart: Int, contentEnd: Int, end: Int, display: Boolean) {
            out.append(if (display) DISPLAY_OPEN else INLINE_OPEN).append(spans.size).append(if (display) DISPLAY_CLOSE else INLINE_CLOSE)
            spans += MathSpan(texOf(s, start, contentStart, contentEnd), display, s.substring(start, end))
        }

        while (i < n) {
            if (lineStart) {
                lineStart = false
                val eol = s.indexOf('\n', i).let { if (it < 0) n else it }
                val content = lineContent(s.substring(i, eol))
                val open = fence
                if (open != null) {
                    if (closesFence(content, open)) fence = null
                } else {
                    fence = opensFence(content)
                }
                if (open != null || fence != null) {
                    out.append(s, i, eol)
                    if (eol < n) out.append('\n')
                    i = eol + 1
                    lineStart = true
                    continue
                }
            }
            val c = s[i]
            when {
                c == '\n' -> {
                    out.append(c)
                    i++
                    lineStart = true
                }
                c == '\\' && i + 1 < n && s[i + 1] != '\n' -> {
                    val next = s[i + 1]
                    if (next == '(' || next == '[') {
                        val end = findCloser(s, i + 2, if (next == '(') "\\)" else "\\]")
                        if (end >= 0 && texOf(s, i, i + 2, end).isNotEmpty()) {
                            addSpan(i, i + 2, end, end + 2, display = next == '[')
                            i = end + 2
                            continue
                        }
                    }
                    out.append(c).append(next)
                    i += 2
                }
                c == '`' -> {
                    var run = 1
                    while (i + run < n && s[i + run] == '`') run++
                    val close = findBacktickRun(s, i + run, run)
                    val end = if (close >= 0) close + run else i + run
                    out.append(s, i, end)
                    i = end
                }
                c == '$' && i + 1 < n && s[i + 1] == '$' -> {
                    val end = findCloser(s, i + 2, "$$")
                    if (end >= 0 && texOf(s, i, i + 2, end).isNotEmpty()) {
                        val display = startsLine(s, i) && onlySpacesAfter(s, end + 2)
                        addSpan(i, i + 2, end, end + 2, display)
                        i = end + 2
                    } else {
                        out.append("$$")
                        i += 2
                    }
                }
                c == '$' -> {
                    val end = findDollarCloser(s, i)
                    if (end >= 0) {
                        addSpan(i, i + 1, end, end + 1, display = false)
                        i = end + 1
                    } else {
                        out.append(c)
                        i++
                    }
                }
                else -> {
                    out.append(c)
                    i++
                }
            }
        }
        return MathExtraction(out.toString(), spans)
    }

    /** A line's content after leading spaces, quote markers and one list marker (where fences are recognised). */
    private fun lineContent(line: String): String {
        var k = 0
        while (k < line.length && (line[k] == ' ' || line[k] == '\t' || line[k] == '>')) k++
        val rest = line.substring(k)
        val marker = LIST_MARKER.find(rest) ?: return rest
        return rest.substring(marker.range.last + 1).trimStart(' ', '\t')
    }

    private fun opensFence(content: String): Fence? {
        val marker = content.firstOrNull() ?: return null
        if (marker != '`' && marker != '~') return null
        val length = content.takeWhile { it == marker }.length
        if (length < 3) return null
        // A backtick fence's info string cannot contain backticks (that line is inline code instead).
        if (marker == '`' && content.indexOf('`', length) >= 0) return null
        return Fence(marker, length)
    }

    private fun closesFence(content: String, fence: Fence): Boolean {
        val run = content.takeWhile { it == fence.marker }.length
        return run >= fence.length && content.substring(run).isBlank()
    }

    /** The next run of exactly [length] backticks from [from], or -1 when a blank line or the end comes first. */
    private fun findBacktickRun(s: String, from: Int, length: Int): Int {
        var k = from
        while (k < s.length) {
            val c = s[k]
            if (c == '\n' && isBlankLineAt(s, k + 1)) return -1
            if (c == '`') {
                var run = 1
                while (k + run < s.length && s[k + run] == '`') run++
                if (run == length) return k
                k += run
                continue
            }
            k++
        }
        return -1
    }

    /** Where [closer] next occurs from [from], skipping escapes, or -1 when a blank line or the end comes first. */
    private fun findCloser(s: String, from: Int, closer: String): Int {
        var k = from
        while (k < s.length) {
            val c = s[k]
            if (c == '\n' && isBlankLineAt(s, k + 1)) return -1
            if (s.startsWith(closer, k)) return k
            k += if (c == '\\' && closer[0] != '\\' && k + 1 < s.length) 2 else 1
        }
        return -1
    }

    /** Rule 4: the closing `$` of a single-dollar span opened at [open], or -1; never inside a later code span. */
    private fun findDollarCloser(s: String, open: Int): Int {
        val first = s.getOrNull(open + 1) ?: return -1
        if (first.isWhitespace()) return -1
        var k = open + 1
        while (k < s.length && s[k] != '\n') {
            val c = s[k]
            if (c == '`') return -1
            if (c == '\\') {
                k += 2
                continue
            }
            if (c == '$' && k > open + 1 && !s[k - 1].isWhitespace() && s.getOrNull(k + 1)?.isDigit() != true) return k
            k++
        }
        return -1
    }

    /** A line holding only spaces and quote markers (a blank line inside a quote) starts at [index]. */
    private fun isBlankLineAt(s: String, index: Int): Boolean {
        var k = index
        while (k < s.length && s[k] != '\n') {
            val c = s[k]
            if (c != ' ' && c != '\t' && c != '>') return false
            k++
        }
        return true
    }

    private fun lineStartOf(s: String, index: Int): Int = s.lastIndexOf('\n', index - 1) + 1

    private fun startsLine(s: String, index: Int): Boolean = LINE_PREFIX.matches(s.substring(lineStartOf(s, index), index))

    private fun onlySpacesAfter(s: String, index: Int): Boolean {
        var k = index
        while (k < s.length && s[k] != '\n') {
            if (s[k] != ' ' && s[k] != '\t') return false
            k++
        }
        return true
    }

    /** Rule 5: the trimmed TeX; continuation lines inside a quote lose as many `>` markers as the opening line had. */
    private fun texOf(s: String, start: Int, contentStart: Int, contentEnd: Int): String {
        val content = s.substring(contentStart, contentEnd)
        if ('\n' !in content) return content.trim()
        val depth = s.substring(lineStartOf(s, start), start).count { it == '>' }
        if (depth == 0) return content.trim()
        val lines = content.split('\n')
        return (listOf(lines.first()) + lines.drop(1).map { dropQuoteMarkers(it, depth) }).joinToString("\n").trim()
    }

    private fun dropQuoteMarkers(line: String, depth: Int): String {
        var k = 0
        var dropped = 0
        while (dropped < depth) {
            while (k < line.length && (line[k] == ' ' || line[k] == '\t')) k++
            if (k >= line.length || line[k] != '>') break
            k++
            if (k < line.length && line[k] == ' ') k++
            dropped++
        }
        return line.substring(k)
    }
}
