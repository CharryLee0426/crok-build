package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.demo.DemoData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyntaxHighlighterTest {
    private fun tokens(code: String, language: String): List<Pair<String, CodeToken>> =
        SyntaxHighlighter.highlight(code, language).map { code.substring(it.start, it.end) to it.token }

    @Test
    fun knowsTheContractsLanguagesAndAliasesOnly() {
        for (name in listOf("swift", "KT", "kts", "rs", "golang", "h", "c++", "objective-c", "c#", "mjs", "tsx", "python3", "rb",
            "php", "zsh", "console", "pwsh", "json5", "yml", "toml", "properties", "sql", "plist", "vue", "less", "patch", "md",
            "docker", "mk", "lua", "dart", "scala", "gql")) {
            assertTrue(name, SyntaxHighlighter.knows(name))
        }
        assertFalse(SyntaxHighlighter.knows("brainfuck"))
        assertFalse(SyntaxHighlighter.knows(null))
        assertEquals(emptyList<CodeSpan>(), SyntaxHighlighter.highlight("val x = 1", null))
        assertEquals(emptyList<CodeSpan>(), SyntaxHighlighter.highlight("val x = 1", "unknown"))
    }

    @Test
    fun kotlin() {
        val code = "fun greet(name: String?): String = \"Hello, \${name ?: \"world\"}!\" // nullable"
        assertEquals(
            listOf(
                "fun" to CodeToken.Keyword,
                "greet" to CodeToken.Function,
                "String" to CodeToken.Type,
                "String" to CodeToken.Type,
                "\"Hello, \${name ?: \"world\"}!\"" to CodeToken.Str,
                "// nullable" to CodeToken.Comment,
            ),
            tokens(code, "kotlin"),
        )
    }

    @Test
    fun python() {
        val code = "@dataclass\nclass User:\n    age: int = 0  # default\n    ok = True if x is not None else 'no'"
        assertEquals(
            listOf(
                "@dataclass" to CodeToken.Meta,
                "class" to CodeToken.Keyword,
                "User" to CodeToken.Type,
                "int" to CodeToken.Type,
                "0" to CodeToken.Number,
                "# default" to CodeToken.Comment,
                "True" to CodeToken.Literal,
                "if" to CodeToken.Keyword,
                "is" to CodeToken.Keyword,
                "not" to CodeToken.Keyword,
                "None" to CodeToken.Literal,
                "else" to CodeToken.Keyword,
                "'no'" to CodeToken.Str,
            ),
            tokens(code, "py"),
        )
    }

    @Test
    fun rustMacrosAndLifetimes() {
        val found = tokens("fn f<'a>(s: &'a str) { println!(\"{}\", s.len()); }", "rs")
        assertTrue(found.contains("println!" to CodeToken.Function))
        assertTrue(found.contains("'a" to CodeToken.Literal))
        assertTrue(found.contains("str" to CodeToken.Type))
        assertTrue(found.contains("len" to CodeToken.Function))
        assertTrue(found.contains("\"{}\"" to CodeToken.Str))
    }

    @Test
    fun jsonKeysValuesAndLiterals() {
        assertEquals(
            listOf("\"name\"" to CodeToken.Property, "\"crok\"" to CodeToken.Str, "\"port\"" to CodeToken.Property,
                "3210" to CodeToken.Number, "\"debug\"" to CodeToken.Property, "null" to CodeToken.Literal),
            tokens("{ \"name\": \"crok\", \"port\": 3210, \"debug\": null }", "json"),
        )
    }

    @Test
    fun diffLines() {
        assertEquals(
            listOf("--- a/x" to CodeToken.Meta, "@@ -1 +1 @@" to CodeToken.Section, "-old" to CodeToken.Deleted, "+new" to CodeToken.Inserted),
            tokens("--- a/x\n@@ -1 +1 @@\n same\n-old\n+new", "diff"),
        )
    }

    @Test
    fun shellAndMarkup() {
        val shell = tokens("#!/usr/bin/env bash\necho \"\$f\" \$HOME # done", "sh")
        assertEquals("#!/usr/bin/env bash" to CodeToken.Meta, shell.first())
        assertTrue(shell.contains("echo" to CodeToken.Builtin))
        assertTrue(shell.contains("\$HOME" to CodeToken.Variable))
        assertTrue(shell.contains("# done" to CodeToken.Comment))
        assertEquals(
            listOf("a" to CodeToken.Tag, "href" to CodeToken.Property, "\"/x\"" to CodeToken.Str, "a" to CodeToken.Tag, "<!-- c -->" to CodeToken.Comment),
            tokens("<a href=\"/x\">it's</a><!-- c -->", "html"),
        )
    }

    @Test
    fun sqlIgnoresCase() {
        val found = tokens("SELECT name FROM users WHERE id = 1 -- one", "sql")
        assertEquals(listOf("SELECT", "FROM", "WHERE"), found.filter { it.second == CodeToken.Keyword }.map { it.first })
        assertTrue(found.contains("-- one" to CodeToken.Comment))
    }

    /** What the bubble pays per frame while a reply streams: parsing the whole reply and highlighting its code. */
    @Test
    fun showcaseParsesAndHighlightsQuickly() {
        val text = DemoData.markdownShowcase
        repeat(20) { Markdown.parse(text) }
        val runs = 200
        val started = System.nanoTime()
        repeat(runs) { index ->
            // A growing text, like a stream: nothing is served from the highlight cache.
            val blocks = Markdown.parse(text + "\n\n```kotlin\nval x$index = 1\n```")
            blocks.filterIsInstance<MdBlock.Code>().forEach { SyntaxHighlighter.highlight(it.text, it.language) }
        }
        val perRun = (System.nanoTime() - started) / runs / 1_000_000.0
        println("markdown showcase: parse + highlight %.2f ms per run (%d chars)".format(perRun, text.length))
        assertTrue("took $perRun ms", perRun < 50)
    }
}
