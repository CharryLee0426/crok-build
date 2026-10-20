package dev.chenli.crok.mobile.logic

import org.junit.Assert.assertEquals
import org.junit.Test

/** relay/DESIGN.md §5 "Replies in Markdown": the test vectors every client checks. */
class MathExtractorTest {
    private fun found(input: String): List<String> =
        MathExtractor.extract(input).spans.map { (if (it.display) "D(" else "I(") + it.tex + ")" }

    @Test
    fun designVectors() {
        assertEquals(listOf("I(e^{i\\pi}+1=0)"), found("Euler: \$e^{i\\pi}+1=0\$."))
        assertEquals(emptyList<String>(), found("costs \$5 and \$10"))
        assertEquals(emptyList<String>(), found("echo \$HOME and \$PATH"))
        assertEquals(emptyList<String>(), found("\$ x \$"))
        assertEquals(emptyList<String>(), found("\$x\$5"))
        assertEquals(listOf("I(x)"), found("the \$x\$-axis"))
        assertEquals(emptyList<String>(), found("\\\$5 and \\\$6"))
        assertEquals(emptyList<String>(), found("`\$x\$` and\n```\n\$y\$\n```"))
        assertEquals(listOf("I(a^2)", "D(b^2)"), found("\\(a^2\\) and \\[b^2\\]"))
        assertEquals(listOf("D(\\int_0^1 x\\,dx)"), found("\$\$\n\\int_0^1 x\\,dx\n\$\$"))
        assertEquals(listOf("I(x)"), found("a \$\$x\$\$ b"))
        assertEquals(listOf("D(a)"), found("> \$\$\n> a\n> \$\$"))
        assertEquals(listOf("I(a|b)"), found("| \$a|b\$ | c |"))
        assertEquals(emptyList<String>(), found("\$\$\n\\frac{a}{"))
        assertEquals(emptyList<String>(), found("price \$5, see `\$x\$`"))
    }

    @Test
    fun unclosedMathLeavesTheTextUnchanged() {
        val text = "Streaming: \$\$\n\\frac{a}{"
        assertEquals(text, MathExtractor.extract(text).text)
        assertEquals("a \$b and `c`", MathExtractor.extract("a \$b and `c`").text)
    }

    @Test
    fun placeholdersAndRestore() {
        val extraction = MathExtractor.extract("x \$a\$ y\n\n\$\$\nb\n\$\$")
        assertEquals("x 0 y\n\n1", extraction.text)
        assertEquals(listOf(MathSpan("a", false, "\$a\$"), MathSpan("b", true, "\$\$\nb\n\$\$")), extraction.spans)
        assertEquals("see \$a\$ and \$\$\nb\n\$\$", extraction.restore("see 0 and 1"))
        assertEquals(listOf("x ", extraction.spans[0], " y"), extraction.split("x 0 y"))
    }

    @Test
    fun displayOnlyWhenAloneOnItsLine() {
        assertEquals(listOf("D(x)"), found("- \$\$x\$\$"))
        assertEquals(listOf("D(x)"), found("   \$\$ x \$\$   "))
        assertEquals(listOf("I(x)"), found("\$\$x\$\$ then text"))
        // A blank line ends the search for the closer.
        assertEquals(emptyList<String>(), found("\$\$\na\n\nb\n\$\$"))
    }

    @Test
    fun codeIsCopiedUntouched() {
        val fenced = "~~~\n\$a\$ \\(b\\)\n~~~\nthen \$c\$"
        assertEquals(listOf("I(c)"), found(fenced))
        assertEquals(listOf("I(y)"), found("``a ` \$x\$`` and \$y\$"))
        assertEquals(listOf("I(z)"), found("- ```\n  \$x\$\n  ```\n- \$z\$"))
    }
}
