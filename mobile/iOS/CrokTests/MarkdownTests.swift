import SwiftUI
import XCTest

@testable import Crok

/// The math scanner against relay/DESIGN.md §5 "Replies in Markdown" (the same vectors as the web and Android).
final class MathExtractorTests: XCTestCase {
    /// `I(tex)` / `D(tex)` for every span found, as DESIGN.md writes them.
    private func found(_ input: String) -> [String] {
        MathExtractor.extract(input).spans.map { "\($0.display ? "D" : "I")(\($0.tex))" }
    }

    func testDesignVectors() {
        XCTAssertEqual(found(#"Euler: $e^{i\pi}+1=0$."#), [#"I(e^{i\pi}+1=0)"#])
        XCTAssertEqual(found("costs $5 and $10"), [])
        XCTAssertEqual(found("echo $HOME and $PATH"), [])
        XCTAssertEqual(found("$ x $"), [])
        XCTAssertEqual(found("$x$5"), [])
        XCTAssertEqual(found("the $x$-axis"), ["I(x)"])
        XCTAssertEqual(found(#"\$5 and \$6"#), [])
        XCTAssertEqual(found("`$x$` and\n\n```\n$y$\n```"), [])
        XCTAssertEqual(found(#"\(a^2\) and \[b^2\]"#), ["I(a^2)", "D(b^2)"])
        XCTAssertEqual(found("$$\n\\int_0^1 x\\,dx\n$$"), [#"D(\int_0^1 x\,dx)"#])
        XCTAssertEqual(found("a $$x$$ b"), ["I(x)"])
        XCTAssertEqual(found("> $$\n> a\n> $$"), ["D(a)"])
        XCTAssertEqual(found("| $a|b$ | c |"), ["I(a|b)"])
        XCTAssertEqual(found("$$\n\\frac{a}{"), [])
        XCTAssertEqual(found("price $5, see `$x$`"), [])
    }

    func testStreamingTextIsUnchanged() {
        let partial = "Almost:\n$$\n\\frac{a}{"
        XCTAssertEqual(MathExtractor.extract(partial).text, partial)
        XCTAssertEqual(MathExtractor.extract("an unclosed $x").text, "an unclosed $x")
    }

    func testPlaceholdersRoundTrip() {
        for input in [
            #"Euler: $e^{i\pi}+1=0$."#, "> $$\n> a\n> $$", #"\(a\) \[b\]"#, "| $a|b$ | c |", "a $$x$$ b", "costs $5",
        ] {
            let extraction = MathExtractor.extract(input)
            XCTAssertEqual(MathExtractor.restore(extraction.text, spans: extraction.spans), input)
        }
    }

    func testPlaceholderShapes() {
        let extraction = MathExtractor.extract("a $x$ b\n\n$$\ny\n$$")
        XCTAssertEqual(extraction.text, "a \u{E000}0\u{E001} b\n\n\u{E002}1\u{E003}")
        XCTAssertEqual(
            MathExtractor.segments(extraction.text, spanCount: 2),
            [.text("a "), .math(0, display: false), .text(" b\n\n"), .math(1, display: true)])
        // A placeholder pointing past the spans stays text.
        XCTAssertEqual(MathExtractor.segments("\u{E000}7\u{E001}", spanCount: 1), [.text("\u{E000}7\u{E001}")])
    }

    func testFencesInListsAndQuotesAreSkipped() {
        XCTAssertEqual(found("- ```\n  $x$\n  ```\n- $y$"), ["I(y)"])
        XCTAssertEqual(found("> ~~~\n> $x$\n> ~~~"), [])
        // A line of backticks with a backtick after is inline code, not a fence.
        XCTAssertEqual(found("```a` $x$"), ["I(x)"])
    }

    func testDisplayNeedsItsOwnLine() {
        XCTAssertEqual(found("1. $$x$$"), ["D(x)"])
        XCTAssertEqual(found("$$x$$ and more"), ["I(x)"])
        XCTAssertEqual(found("$$\na\n\nb\n$$"), [], "not across a blank line")
    }
}

final class MarkdownDocumentTests: XCTestCase {
    private func blocks(_ text: String) -> [MDBlock] { MDDocument.parse(text).blocks }

    func testInlineMarkup() {
        let parsed = blocks("A **b** *c* ~~d~~ `e` [f](https://x.dev) [g](src/main.rs) https://y.dev")
        XCTAssertEqual(
            parsed,
            [
                .paragraph([
                    .text("A "), .strong([.text("b")]), .text(" "), .emphasis([.text("c")]), .text(" "),
                    .strikethrough([.text("d")]), .text(" "), .code("e"), .text(" "),
                    .link(URL(string: "https://x.dev")!, [.text("f")]), .text(" "), .text("g"), .text(" "),
                    .link(URL(string: "https://y.dev")!, [.text("https://y.dev")]),
                ])
            ])
    }

    func testSingleNewlineIsALineBreakAndPunctuationStaysAsWritten() {
        XCTAssertEqual(
            blocks("one\ntwo -- \"three\" --flag"), [.paragraph([.text("one"), .lineBreak, .text(#"two -- "three" --flag"#)])])
    }

    func testEscapedDollars() {
        XCTAssertEqual(blocks(#"\$5 and \$6"#), [.paragraph([.text("$5 and $6")])])
    }

    func testHeadingsListsAndQuotes() {
        let parsed = blocks("## Title\n\n3. three\n4. four\n   - nested\n\n- [x] done\n- [ ] todo\n\n> a\n>\n> > b")
        XCTAssertEqual(parsed.first, .heading(level: 2, [.text("Title")]))
        XCTAssertEqual(
            parsed[1],
            .list(
                MDList(
                    ordered: true, start: 3,
                    items: [
                        MDListItem(task: nil, blocks: [.paragraph([.text("three")])]),
                        MDListItem(
                            task: nil,
                            blocks: [
                                .paragraph([.text("four")]),
                                .list(MDList(ordered: false, start: 1, items: [MDListItem(task: nil, blocks: [.paragraph([.text("nested")])])])),
                            ]),
                    ])))
        XCTAssertEqual(
            parsed[2],
            .list(
                MDList(
                    ordered: false, start: 1,
                    items: [
                        MDListItem(task: true, blocks: [.paragraph([.text("done")])]),
                        MDListItem(task: false, blocks: [.paragraph([.text("todo")])]),
                    ])))
        XCTAssertEqual(parsed[3], .quote([.paragraph([.text("a")]), .quote([.paragraph([.text("b")])])]))
    }

    func testTables() {
        let parsed = blocks("| a | b | c |\n|:--|:-:|--:|\n| $x|y$ | one<br>two | `z` |")
        guard case .table(let table) = parsed.first else { return XCTFail("\(parsed)") }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.header, [[.text("a")], [.text("b")], [.text("c")]])
        XCTAssertEqual(table.rows, [[[.math(0)], [.text("one"), .lineBreak, .text("two")], [.code("z")]]])
        XCTAssertEqual(MDDocument.parse("| $x|y$ |\n|--|\n").math.first?.tex, "x|y")
    }

    func testCodeBlocks() {
        XCTAssertEqual(blocks("```swift\nlet a = \"$x$\"\n```"), [.code(language: "swift", code: "let a = \"$x$\"")])
        XCTAssertEqual(blocks("Here:\n```\nline 1\nline 2"), [.paragraph([.text("Here:")]), .code(language: nil, code: "line 1\nline 2")])
        // Indented code is not skipped by the scanner, so its placeholder is put back.
        XCTAssertEqual(blocks("Text\n\n    cost $x$ here"), [.paragraph([.text("Text")]), .code(language: nil, code: "cost $x$ here")])
    }

    func testDisplayMathStandsOnItsOwn() {
        let document = MDDocument.parse("Before\n$$\nE=mc^2\n$$\nafter \\[y\\] end")
        XCTAssertEqual(
            document.blocks,
            [.paragraph([.text("Before")]), .math(0), .paragraph([.text("after ")]), .math(1), .paragraph([.text(" end")])])
        XCTAssertEqual(document.math.map(\.tex), ["E=mc^2", "y"])
        XCTAssertEqual(MDDocument.parse("> $$\n> a\n> $$").blocks, [.quote([.math(0)])])
    }

    func testImagesAreLinksAndHTMLIsText() {
        XCTAssertEqual(
            blocks("![logo](https://x.dev/a.png) ![](https://x.dev/b.png) ![p](file.png)"),
            [
                .paragraph([
                    .link(URL(string: "https://x.dev/a.png")!, [.text("🖼 logo")]), .text(" "),
                    .link(URL(string: "https://x.dev/b.png")!, [.text("🖼 https://x.dev/b.png")]), .text(" "), .text("🖼 p"),
                ])
            ])
        XCTAssertEqual(
            blocks("Raw <div class=\"x\">not</div> a<BR/>b"),
            [.paragraph([.text("Raw "), .text("<div class=\"x\">"), .text("not"), .text("</div>"), .text(" a"), .lineBreak, .text("b")])])
        XCTAssertEqual(blocks("<div>\nblock\n</div>"), [.paragraph([.text("<div>"), .lineBreak, .text("block"), .lineBreak, .text("</div>")])])
    }

    func testUnclosedEmphasisStaysLiteral() {
        XCTAssertEqual(blocks("a **half"), [.paragraph([.text("a **half")])])
    }

    func testDemoShowcaseMatchesTheFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("relay/scripts/markdown-showcase.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(DemoWorld.markdownShowcase + "\n", text, "re-copy relay/scripts/markdown-showcase.md into DemoShowcase.swift")
    }

    func testShowcaseParses() {
        let document = MDDocument.parse(DemoWorld.markdownShowcase)
        var codeLanguages: [String?] = []
        var tables = 0
        var displays = 0
        func walk(_ blocks: [MDBlock]) {
            for block in blocks {
                switch block {
                case .code(let language, _): codeLanguages.append(language)
                case .table: tables += 1
                case .math: displays += 1
                case .quote(let inner): walk(inner)
                case .list(let list): list.items.forEach { walk($0.blocks) }
                default: break
                }
            }
        }
        walk(document.blocks)
        XCTAssertEqual(codeLanguages, ["swift", "kotlin", "rust", "python", "ts", "bash", "json", "diff", nil])
        XCTAssertEqual(tables, 2)
        XCTAssertEqual(displays, 3)
        XCTAssertEqual(
            document.math.map(\.display), [false, false, false, false, true, true, true, false],
            document.math.map(\.tex).joined(separator: " · "))
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    private func tokens(_ code: String, _ language: String) -> [String: CodeToken] {
        let text = code as NSString
        var out: [String: CodeToken] = [:]
        for run in SyntaxHighlighter.highlight(code, language: language) {
            out[text.substring(with: NSRange(location: run.location, length: run.length))] = run.token
        }
        return out
    }

    func testEveryAliasCompiles() {
        for alias in SyntaxHighlighter.aliases {
            let grammar = SyntaxHighlighter.grammar(for: alias)
            XCTAssertNotNil(grammar?.regex, alias)
            if let grammar, let regex = grammar.regex {
                XCTAssertEqual(regex.numberOfCaptureGroups, grammar.rules.count + (grammar.hasIdentifiers ? 1 : 0), alias)
            }
        }
        XCTAssertNotNil(SyntaxHighlighter.grammar(for: " Swift "))
    }

    func testUnknownOrMissingLanguageIsPlain() {
        XCTAssertEqual(SyntaxHighlighter.highlight("let x = 1", language: nil), [])
        XCTAssertEqual(SyntaxHighlighter.highlight("let x = 1", language: "brainfuck"), [])
    }

    func testSwift() {
        let found = tokens("struct Point { func distance(to other: Point) -> Double { return 1.5 } } // done \"x\"\nlet s = \"hi\"", "swift")
        XCTAssertEqual(found["struct"], .keyword)
        XCTAssertEqual(found["Point"], .type)
        XCTAssertEqual(found["distance"], .function)
        XCTAssertEqual(found["Double"], .type)
        XCTAssertEqual(found["1.5"], .number)
        XCTAssertEqual(found["// done \"x\""], .comment)
        XCTAssertEqual(found["\"hi\""], .string)
    }

    func testPythonJsonDiffBashMarkup() {
        let python = tokens("@dataclass\nclass User:\n    def adults(self) -> None:\n        return True  # yes", "py")
        XCTAssertEqual(python["@dataclass"], .meta)
        XCTAssertEqual(python["User"], .type)
        XCTAssertEqual(python["adults"], .function)
        XCTAssertEqual(python["None"], .literal)
        XCTAssertEqual(python["# yes"], .comment)

        let json = tokens(#"{ "name": "crok", "port": 3210, "debug": null }"#, "json")
        XCTAssertEqual(json[#""name""#], .property)
        XCTAssertEqual(json[#""crok""#], .string)
        XCTAssertEqual(json["3210"], .number)
        XCTAssertEqual(json["null"], .literal)

        let diff = tokens("@@ -1 +1 @@\n context\n-old\n+new", "diff")
        XCTAssertEqual(diff["@@ -1 +1 @@"], .section)
        XCTAssertEqual(diff["-old"], .deleted)
        XCTAssertEqual(diff["+new"], .inserted)
        XCTAssertNil(diff[" context"])

        let bash = tokens("#!/usr/bin/env bash\nfor f in *.log; do echo \"$f\" $HOME; done # count", "sh")
        XCTAssertEqual(bash["#!/usr/bin/env bash"], .meta)
        XCTAssertEqual(bash["for"], .keyword)
        XCTAssertEqual(bash["echo"], .builtin)
        XCTAssertEqual(bash["$HOME"], .variable)
        XCTAssertEqual(bash["# count"], .comment)

        let html = tokens(#"<a href="https://x.dev" hidden>link</a> <!-- note -->"#, "html")
        XCTAssertEqual(html["<a"], .tag)
        XCTAssertEqual(html["href"], .property)
        XCTAssertEqual(html[#""https://x.dev""#], .string)
        XCTAssertEqual(html["</a"], .tag)
        XCTAssertEqual(html["<!-- note -->"], .comment)
        XCTAssertNil(html["link"])
    }

    func testRustTypeScriptAndSql() {
        let rust = tokens("fn main() { println!(\"{}\", 'a'); let v: Vec<u32> = vec![]; }", "rs")
        XCTAssertEqual(rust["fn"], .keyword)
        XCTAssertEqual(rust["main"], .function)
        XCTAssertEqual(rust["println!"], .function)
        XCTAssertEqual(rust["'a'"], .string)
        XCTAssertEqual(rust["u32"], .type)
        XCTAssertEqual(rust["Vec"], .type)

        let ts = tokens("export async function fetchJson<T>(url: string): Promise<T> { const re = /a+/g; }", "ts")
        XCTAssertEqual(ts["export"], .keyword)
        XCTAssertEqual(ts["fetchJson"], .function)
        XCTAssertEqual(ts["string"], .type)
        XCTAssertEqual(ts["Promise"], .builtin)
        XCTAssertEqual(ts[" /a+/g"], .regex)

        let sql = tokens("SELECT count(*) FROM users WHERE name = 'x' -- all", "sql")
        XCTAssertEqual(sql["SELECT"], .keyword)
        XCTAssertEqual(sql["count"], .builtin)
        XCTAssertEqual(sql["'x'"], .string)
        XCTAssertEqual(sql["-- all"], .comment)
    }
}

/// How long a reply takes to parse and highlight, which a streaming reply pays up to 30 times a second.
@MainActor
final class MarkdownTimingTests: XCTestCase {
    func testShowcaseParsesAndHighlightsQuickly() {
        let text = DemoWorld.markdownShowcase
        _ = MDDocument.parse(text)  // warm up (grammars compile once)
        for (language, code) in Self.codeBlocks(MDDocument.parse(text)) { _ = SyntaxHighlighter.highlight(code, language: language) }
        let rounds = 20
        let start = Date()
        for _ in 0..<rounds {
            let document = MDDocument.parse(text)
            for (language, code) in Self.codeBlocks(document) { _ = SyntaxHighlighter.highlight(code, language: language) }
        }
        let perRound = Date().timeIntervalSince(start) / Double(rounds) * 1000
        print("Markdown showcase: parse + highlight \(String(format: "%.2f", perRound)) ms per render")
        XCTAssertLessThan(perRound, 30, "a streaming reply re-renders every frame")
    }

    func testShowcaseLaysOut() {
        // A smoke test of the whole view tree (tables, math, code) at phone width, timed.
        let view = MarkdownText(text: DemoWorld.markdownShowcase).frame(width: 340).padding(12)
        let start = Date()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = renderer.uiImage
        let elapsed = Date().timeIntervalSince(start) * 1000
        print("Markdown showcase: first layout + draw \(String(format: "%.1f", elapsed)) ms, size \(image?.size ?? .zero)")
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.height ?? 0, 1000)
        // Again with fonts, grammars and math warm: what each frame of a streaming reply costs, plus drawing.
        let warmStart = Date()
        let again = ImageRenderer(content: MarkdownText(text: DemoWorld.markdownShowcase + " ").frame(width: 340).padding(12))
        again.scale = 1
        _ = again.uiImage
        print("Markdown showcase: warm layout + draw \(String(format: "%.1f", Date().timeIntervalSince(warmStart) * 1000)) ms")
    }

    static func codeBlocks(_ document: MDDocument) -> [(String?, String)] {
        var out: [(String?, String)] = []
        func walk(_ blocks: [MDBlock]) {
            for block in blocks {
                switch block {
                case .code(let language, let code): out.append((language, code))
                case .quote(let inner): walk(inner)
                case .list(let list): list.items.forEach { walk($0.blocks) }
                default: break
                }
            }
        }
        walk(document.blocks)
        return out
    }
}
