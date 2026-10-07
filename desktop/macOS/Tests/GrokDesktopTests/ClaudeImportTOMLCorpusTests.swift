import XCTest
@testable import GrokDesktop

/// Documents checked against Crok's own TOML parser (the `toml` 0.9.12 crate, TOML 1.1) to pin
/// which files the importer will edit and which it refuses: the two must agree on every one.
final class ClaudeImportTOMLCorpusTests: XCTestCase {
    private let acceptedByGrok = [
        "k = 1", "k = +1", "k = -1", "k = 0", "k = -0", "k = +0", "k = 1_000", "k = 0x1F", "k = 0o17", "k = 0b101", "k = 9223372036854775807",
        "k = -9223372036854775808", "k = 0x7FFFFFFFFFFFFFFF", "k = 1.0", "k = 1.5e3", "k = 1e3", "k = 1E-3", "k = 1e+3", "k = -0.0", "k = +1.5",
        "k = 3.14_15", "k = inf", "k = +inf", "k = -inf", "k = nan", "k = +nan", "k = -nan", "k = true", "k = false", "k = 1979-05-27",
        "k = 1979-05-27T07:32:00", "k = 1979-05-27T07:32", "k = 1979-05-27 07:32:00Z", "k = 1979-05-27T07:32:00.999999Z",
        "k = 1979-05-27T07:32:00+01:00", "k = 07:32:00", "k = 07:32", "k = 07:32:00.5", "k = 2000-02-29", "k = \"a\"", "k = \"a\\tb\"",
        "k = \"\\u00E9\"", "k = \"\\U0001F600\"", "k = \"\\x41\"", "k = \"\\e\"", "k = \"a\\\"b\"", "k = \"tab\there\"", "k = 'lit'", "k = 'lit\\n'",
        "k = ''", "k = \"\"", "k = \"\"\"a\"\"\"", "k = '''a'''", "k = \"\"\"\na\n\"\"\"", "k = \"\"\"\"a\"\"\"\"", "k = \"\"\"\"\"a\"\"\"\"\"",
        "k = ''''a''''", "k = []", "k = [1,2]", "k = [1,2,]", "k = [ 1 , 2 ]", "k = [\n1,\n2\n]", "k = [[1],[2]]", "k = [{a=1},{b=2}]",
        "k = [1, 'a', 2.0]", "k = {}", "k = {a=1}", "k = {a=1,}", "k = { a = 1 , b = 2 }", "k = {a.b=1,a.c=2}", "k = {\na=1\n}",
        "[a]\nx=1\n[b]\ny=2", "[a.b]\n[a]", "[a]\n[a.b]", "[[a]]\n[[a]]", "[[a]]\n[a.b]\n[[a]]\n[a.b]", "[[a.b]]\n[a]\nc=1", "[a]\nb.c=1\n[a.b.d]",
        "a.b=1\na.c=2", "\"a.b\"=1\na.b=2", "[ a.b ]\n[ \"a\" . 'b' . c ]", "[a]\n\"\"=1", "# c\n", "a=1 # c", "a=1#c", "a=\"x\"#c",
        "a = 1\n  # indented comment\n\tb = 2", "  [a]  # c\n  x = 1", "a=1\r\nb=2\r\n", "a=1\n\n\n[t]\n\n", "a = \"\"\"\nx\\\n   y\"\"\"",
        "a = '''\n\\x'''", "k = [\n  1, # one\n  2, # two\n]\n", "k = { a = 1, # c\n b = 2 }", "\u{feff}a=1", "bare-key_1 = 1", "\"é\" = 1",
        "1234 = 1", "1.2 = 1", "true = 1", "[a.b.c]\nx=1\n[a.b]\ny=2\n[a]\nz=3", "[a]\n[a.b.c]\n[a.b]",
        "[[a.b]]\nx=1\n[a.b.c]\ny=2\n[[a.b]]\n[a.b.c]", "[[a]]\n[[a.b]]\n[[a.b]]\n[[a]]\n[[a.b]]", "[a.b]\n[[a.b.c]]\n[a.b.c.d]",
        "x.y.z = 1\nx.y.w = 2\n[x.v]", "[t]\na.b.c = 1\na.b.d = 2\n[t.a.b.e]\nq=1", "k = [\"a\",\n\"b\"\n,]", "k = [\n\n]",
        "k=[#c\n1#c\n,#c\n2#c\n]", "k = [ [ ], [ [ ] ] ]", "k = [1,[2,[3]]]", "k = [{}, {a.b=1}]", "k = { a = [1,\n2] }",
        "k = { a = \"\"\"x\ny\"\"\" }", "a = \"\"\"\\u00E9\\U0001F600\"\"\"", "a = \"\"\"   \\\n\n\n   x\"\"\"", "a = \"\"\"x\\ \n y\"\"\"",
        "a = '''x\\y'''", "a = \"\"\"\"\"\"", "a = \"\"\"\"\"\"\"", "a = \"\"\"\"\"\"\"\"", "a = ''''''", "a = '''''''", "a = \"\\u0000\"",
        "a = \"\\x80\"", "a = '\\u00E9'", "a = \"\"\"a\r\nb\"\"\"", "a = '''a\r\nb'''", "a = 1979-05-27T07:32:00Z\nb = 1979-05-27t07:32:00z",
        "a = 1979-05-27 ", "a = 0001-01-01", "a = 9999-12-31T23:59:60Z", "a = 1_2_3", "a = 0b1_0_1", "a = 1e0_1", "a = false\n",
        "\t\ta = 1\n\t[b]\n\t\tc = 2", "a\t=\t1", "a=1\t#\tc", "[a]\t#c", "[[a]]#c", "[\"\"]", "[''.'']", "a.\"\".b = 1", "\"\\u0061\" = 1",
    ]

    private let rejectedByGrok = [
        "k = 01", "k = 1__000", "k = _1", "k = 1_", "k = 0X1F", "k = 0x_1", "k = 0xG", "k = 0o8", "k = 0b2", "k = +0x1", "k = 9223372036854775808",
        "k = -9223372036854775809", "k = 0x8000000000000000", "k = 1.", "k = 1e", "k = 1.e3", "k = 3._14", "k = Inf", "k = NaN", "k = True",
        "k = tru", "k = truex", "k = 1979-5-27", "k = 1979-05-27T07:32:00+1:00", "k = 1979-05-27T07:32:00-24:00", "k = 1979-05-27T07:32:61",
        "k = 1979-05-27T07:60:00", "k = 7:32:00", "k = 24:00", "k = 2001-02-29", "k = 1900-02-29", "k = 2000-04-31", "k = 1979-00-01",
        "k = 1979-05-00", "k = \"\\uD800\"", "k = \"\\u12\"", "k = \"\\z\"", "k = [,]", "k = [1,,2]", "k = [1 2]", "k = {a=1,a=2}",
        "k = {a={b=1},a.c=2}", "k = {a=1 b=2}", "k = {a}", "[a]\n[a]", "[a.b]\n[a]\n[a]", "[[a]]\n[a]", "[a]\n[[a]]", "a=1\n[a]", "a=[]\n[[a]]",
        "[a]\nb=1\n[a.b]", "a.b=1\na.b.c=2", "a.b=1\na=2", "a = {b=1}\n[a.c]", "[x.y]\n[x]\ny.z=1", "a.\"b.c\"=1\n[a]", "['a']\n[\"a\"]", "[]",
        "[a.]", "[.a]", "[a..b]", "a..b=1", ".a=1", "a.=1", "#c\u{1}", "a=1\rb=2", "a = 1\nb", "a.b = 1\n[a.b.c]", "[a]\nb = { c = 1 }\n[a.b.d]",
        "a = \"\\\n\"", "é = 1", "a b = 1", "[a.b.c]\n[a.b.c.d]\n[a.b.c]", "[[a]]\nb=1\n[a.b]", "[a]\nb=[{c=1}]\n[[a.b]]", "x.y.z = 1\n[x.y]",
        "x.y.z = 1\n[x]", "[t]\na.b=1\n[t.a]", "k = {a=1}\nk.b=2", "[k]\na={b=1}\n[k.a.c]", "a = \"\"\"x\\y\"\"\"", "a = '''''''''",
        "a = \"\"\"a\"\"\"\"\"\"", "a = \"\\U00110000\"", "a = \"\\uDFFF\"", "a = \"\\xZZ\"", "a = \"\u{7f}\"", "a = '\u{7f}'",
        "a = \"\"\"\u{7f}\"\"\"", "a = \"\"\"a\rb\"\"\"", "\"a\nb\" = 1", "'''a''' = 1", "\"\"\"a\"\"\" = 1", "a = 1979-05-27T07:32:00.Z",
        "a = 1979-05-27T07:32:00.", "a = 07:32:00Z", "a = 1979-05-27Z", "a = 1979-05-27  07:32:00", "a = 1979-05-27_07:32:00", "a = 12345-01-01",
        "a = 0_0", "a = 0_1", "a = -_1", "a = 0x_", "a = 0x1_", "a = 1.0e_1", "a = 1_.0", "a = 1._0", "a = +", "a = -", "a = +-1", "a = 1+1",
        "a = 0.0.0", "a = 1e1e1", "a = 1.0f", "a = 0xffffffffffffffff", "a = -0x1", "a = 00", "a = -01", "a = inff", "a = in", "a = -inf_", "a = na",
        "a = trueish", "a = TRUE", "a = t\nb = 1", "a = 1\n\u{c}", "a = 1\n\u{b}", "[a b]", "[a\"b\"]", "[\"a\"b]", "['a'.\"b\"]\n[a.b]",
        "[a]\n['a']", "a = 1\n'a' = 2", "a = 1\n\"a\" = 2", "a = 1\n\"\\u0061\" = 2", "'\\u0061' = 1\n\"\\\\u0061\" = 2",
    ]

    func testParserAgreesWithGrokOnEveryDocument() {
        for document in acceptedByGrok { XCTAssertNoThrow(try ClaudeTOMLDocument(document), document) }
        for document in rejectedByGrok { XCTAssertThrowsError(try ClaudeTOMLDocument(document), document) }
        XCTAssertEqual(acceptedByGrok.count + rejectedByGrok.count, 283)
    }
}
