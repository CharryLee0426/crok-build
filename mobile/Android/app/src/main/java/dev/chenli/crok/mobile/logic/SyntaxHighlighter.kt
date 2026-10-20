package dev.chenli.crok.mobile.logic

import androidx.collection.LruCache
import java.util.regex.Pattern

/** What a piece of code is, for colouring (relay/DESIGN.md §5 "Replies in Markdown", token classes). */
enum class CodeToken { Comment, Keyword, Str, Number, Literal, Function, Type, Builtin, Property, Tag, Variable, Meta, Regex, Inserted, Deleted, Section }

/** A coloured range of code, `[start, end)`. */
data class CodeSpan(val start: Int, val end: Int, val token: CodeToken)

/**
 * A small highlighter for fenced code (the same design and languages as the iOS app's): per language, a list of regex
 * rules run as one alternation, so the regex engine jumps from token to token; identifiers are then classified by
 * keyword sets (a name before `(` is a function; in languages that capitalize types, a capitalized name is a type).
 * An unknown or missing language gets no colours.
 */
object SyntaxHighlighter {
    /** Highlighted code, remembered by language and text (a streaming block re-highlights only when it grows). */
    private val cache = LruCache<String, List<CodeSpan>>(64)

    fun knows(language: String?): Boolean = grammarFor(language) != null

    fun highlight(code: String, language: String?): List<CodeSpan> {
        val grammar = grammarFor(language) ?: return emptyList()
        val key = language!!.lowercase() + '\u0000' + code
        cache[key]?.let { return it }
        val out = ArrayList<CodeSpan>()
        grammar.tokenize(code, 0, code.length, out)
        cache.put(key, out)
        return out
    }

    fun grammarFor(language: String?): Grammar? {
        val name = language?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        val id = ALIASES[name] ?: return null
        return synchronized(grammars) { grammars.getOrPut(id) { build(id) } }
    }

    private val grammars = HashMap<String, Grammar>()

    private val ALIASES: Map<String, String> = buildMap {
        fun alias(id: String, vararg names: String) {
            put(id, id)
            for (name in names) put(name, id)
        }
        alias("swift")
        alias("kotlin", "kt", "kts")
        alias("java")
        alias("rust", "rs")
        alias("go", "golang")
        alias("c", "h")
        alias("cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c", "m", "mm")
        alias("csharp", "cs", "c#")
        alias("javascript", "js", "mjs", "cjs")
        alias("jsx")
        alias("typescript", "ts", "mts")
        alias("tsx")
        alias("python", "py", "python3")
        alias("ruby", "rb")
        alias("php")
        alias("bash", "sh", "shell", "zsh", "console", "shellsession")
        alias("powershell", "ps1", "pwsh")
        alias("json", "jsonc", "json5")
        alias("yaml", "yml")
        alias("toml")
        alias("ini", "cfg", "conf", "properties")
        alias("sql")
        alias("html", "xml", "svg", "plist", "xhtml", "vue")
        alias("css", "scss", "less")
        alias("diff", "patch")
        alias("markdown", "md")
        alias("dockerfile", "docker")
        alias("makefile", "make", "mk")
        alias("lua")
        alias("dart")
        alias("scala")
        alias("graphql", "gql")
    }

    // ---- Shared rules ----

    private const val LINE_COMMENT = "//.*"
    private const val BLOCK_COMMENT = "/\\*[\\s\\S]*?(?:\\*/|\\z)"
    private const val HASH_COMMENT = "#.*"
    private const val DQ = "\"(?:\\\\.|[^\"\\\\\\n])*\""
    private const val SQ = "'(?:\\\\.|[^'\\\\\\n])*'"
    private const val TRIPLE_DQ = "\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"
    private const val TRIPLE_SQ = "'''[\\s\\S]*?(?:'''|\\z)"
    /** A double-quoted string whose `${…}` templates may hold quotes of their own. */
    private const val DQ_TEMPLATED = "\"(?:\\\\.|\\$\\{[^}\\n]*\\}|[^\"\\\\\\n])*\""
    private const val CHAR = "'(?:\\\\.|[^'\\\\\\n])'"
    private const val NUMBER =
        "(?:(?<![\\w$])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)" +
            "|(?<![\\w$.])\\.\\d[\\d_]*(?:[eE][+-]?\\d+)?)(?:[A-Za-z_]\\w*)?"
    private const val ANNOTATION = "@[A-Za-z_][\\w.:]*"
    private const val IDENT = "[\\p{L}_][\\p{L}\\p{N}_]*"

    private fun words(text: String): Set<String> = text.trim().split(Regex("\\s+")).toSet()

    private fun build(id: String): Grammar = when (id) {
        "swift" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, TRIPLE_DQ), Rule(CodeToken.Str, "#?\"(?:\\\\\\([^)\\n]*\\)|\\\\.|[^\"\\\\\\n])*\"#?"),
                Rule(CodeToken.Meta, "@[A-Za-z_]\\w*"), Rule(CodeToken.Meta, "#[A-Za-z_]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator " +
                    "private precedencegroup protocol public rethrows static struct subscript typealias var break case catch " +
                    "continue default defer do else fallthrough for guard if in repeat return throw throws switch where while " +
                    "as is try await async actor some any nonisolated isolated consuming borrowing mutating nonmutating " +
                    "override final required convenience lazy weak unowned dynamic indirect get set willSet didSet macro " +
                    "package sending",
            ),
            literals = words("true false nil self Self super"),
            types = words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat Bool String Character Void Any AnyObject Never"),
            builtins = words("print debugPrint fatalError precondition assert min max abs zip stride"),
            capitalizedTypes = true,
        )
        "kotlin" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, TRIPLE_DQ), Rule(CodeToken.Str, DQ_TEMPLATED), Rule(CodeToken.Str, CHAR),
                Rule(CodeToken.Meta, ANNOTATION), Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "package import class interface fun object val var typealias constructor by companion init if else when try " +
                    "catch finally for do while throw return continue break as is in out where get set field abstract actual " +
                    "annotation crossinline data enum expect external final infix inline inner internal lateinit noinline open " +
                    "operator override private protected public reified sealed suspend tailrec vararg value const",
            ),
            literals = words("true false null this super it"),
            types = words("Int Long Short Byte Double Float Boolean Char String Unit Any Nothing"),
            builtins = words("println print listOf mutableListOf mapOf mutableMapOf setOf arrayOf require check error TODO lazy run let apply also with repeat"),
            capitalizedTypes = true,
        )
        "java" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, TRIPLE_DQ), Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, CHAR),
                Rule(CodeToken.Meta, ANNOTATION), Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "abstract assert break case catch class const continue default do else enum extends final finally for goto if " +
                    "implements import instanceof interface native new package private protected public return static strictfp " +
                    "super switch synchronized this throw throws transient try volatile while var record sealed permits yield",
            ),
            literals = words("true false null this super"),
            types = words("boolean byte char double float int long short void String Object Integer"),
            capitalizedTypes = true,
        )
        "rust" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Meta, "#!?\\[[^\\]\\n]*\\]"),
                Rule(CodeToken.Str, "r#\"[\\s\\S]*?\"#|b?r\"[^\"]*\""),
                Rule(CodeToken.Str, "b?\"(?:\\\\.|[^\"\\\\])*\""),
                Rule(CodeToken.Str, "b?'(?:\\\\.|[^\\\\'\\n])'"),
                Rule(CodeToken.Literal, "'[A-Za-z_]\\w*\\b(?!')"),
                Rule(CodeToken.Function, "[A-Za-z_]\\w*!(?=\\s*[(\\[{])"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut " +
                    "pub ref return static struct super trait type unsafe use where while union",
            ),
            literals = words("true false self Self"),
            types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
            builtins = words("Some None Ok Err"),
            capitalizedTypes = true,
        )
        "go" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, "`[^`]*`"), Rule(CodeToken.Str, "'(?:\\\\.|[^'\\\\\\n])+'"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "break case chan const continue default defer else fallthrough for func go goto if import interface map " +
                    "package range return select struct switch type var",
            ),
            literals = words("true false nil iota"),
            types = words(
                "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 " +
                    "uint16 uint32 uint64 uintptr any comparable",
            ),
            builtins = words("append cap close complex copy delete imag len make new panic print println real recover min max clear"),
        )
        "c", "cpp" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Meta, "^[ \\t]*#[ \\t]*[A-Za-z_]\\w*.*"),
                Rule(CodeToken.Str, "(?:L|u8|u|U|@)?" + DQ), Rule(CodeToken.Str, "(?:L|u8|u|U)?" + CHAR),
                Rule(CodeToken.Keyword, "@[A-Za-z_]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof " +
                    "static struct switch typedef union volatile while" +
                    if (id == "c") {
                        ""
                    } else {
                        " alignas alignof asm catch class constexpr const_cast consteval constinit co_await co_return " +
                            "co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept operator " +
                            "private protected public reinterpret_cast requires static_assert static_cast template thread_local " +
                            "throw try typeid typename using virtual concept override final"
                    },
            ),
            literals = words("true false NULL nullptr this YES NO nil Nil self super"),
            types = words(
                "void char short int long float double signed unsigned bool size_t ssize_t int8_t int16_t int32_t int64_t " +
                    "uint8_t uint16_t uint32_t uint64_t wchar_t char16_t char32_t BOOL id SEL instancetype",
            ),
            builtins = words("printf fprintf sprintf snprintf malloc calloc realloc free memcpy memset strlen strcmp std cout cerr endl"),
            capitalizedTypes = id == "cpp",
        )
        "csharp" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Meta, "^[ \\t]*#[ \\t]*[A-Za-z_]\\w*.*"),
                Rule(CodeToken.Str, "\\$?@\"(?:\"\"|[^\"])*\""), Rule(CodeToken.Str, "\\$?" + DQ), Rule(CodeToken.Str, CHAR),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "abstract as base break case catch checked class const continue default delegate do else enum event explicit " +
                    "extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out " +
                    "override params private protected public readonly ref return sealed sizeof stackalloc static struct switch " +
                    "throw try typeof unchecked unsafe using virtual volatile while async await var dynamic get set init record " +
                    "required yield where when with nameof partial",
            ),
            literals = words("true false null this"),
            types = words("bool byte sbyte char decimal double float int uint long ulong short ushort object string void nint nuint"),
            capitalizedTypes = true,
        )
        "javascript", "jsx", "typescript", "tsx" -> {
            val ts = id == "typescript" || id == "tsx"
            val jsx = id == "jsx" || id == "tsx"
            Grammar(
                buildList {
                    add(Rule(CodeToken.Comment, LINE_COMMENT))
                    add(Rule(CodeToken.Comment, BLOCK_COMMENT))
                    add(Rule(CodeToken.Str, "`(?:\\\\.|\\$\\{[^}]*\\}|[^`\\\\])*`"))
                    add(Rule(CodeToken.Str, DQ))
                    add(Rule(CodeToken.Str, SQ))
                    add(
                        Rule(
                            CodeToken.Regex,
                            "(?<=(?:^|[=(,:;!&|?{}\\[]|\\breturn|\\btypeof)[ \\t]{0,8})/(?![*/])" +
                                "(?:\\\\.|\\[(?:\\\\.|[^\\]\\\\\\n])*\\]|[^/\\\\\\n\\[])+/[dgimsuyv]*",
                        ),
                    )
                    if (jsx) add(Rule(CodeToken.Tag, "(?<=^|[\\s(>{,])</?[A-Za-z][\\w.:-]*(?=[\\s/>])"))
                    add(Rule(CodeToken.Meta, "@[A-Za-z_]\\w*"))
                    add(Rule(CodeToken.Number, NUMBER))
                },
                keywords = words(
                    "break case catch class const continue debugger default delete do else export extends finally for function " +
                        "if import in instanceof let new return switch throw try typeof var void while with yield async await " +
                        "of static get set from as" +
                        if (ts) {
                            " type interface enum implements declare namespace module abstract private protected public " +
                                "readonly keyof infer is satisfies override accessor asserts unique"
                        } else {
                            ""
                        },
                ),
                literals = words("true false null undefined NaN Infinity this super"),
                types = if (ts) words("string number boolean any unknown never void object symbol bigint") else emptySet(),
                builtins = words("console window document globalThis JSON Math Object Array Promise Date Error RegExp Symbol fetch require module exports process setTimeout setInterval parseInt parseFloat"),
                capitalizedTypes = true,
                identifier = "[\\p{L}_$][\\p{L}\\p{N}_$]*",
            )
        }
        "python" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Meta, "^[ \\t]*@[\\w.]+"),
                Rule(CodeToken.Str, "(?i:[rbuf]{0,2})" + TRIPLE_DQ), Rule(CodeToken.Str, "(?i:[rbuf]{0,2})" + TRIPLE_SQ),
                Rule(CodeToken.Str, "(?i:[rbuf]{0,2})" + DQ), Rule(CodeToken.Str, "(?i:[rbuf]{0,2})" + SQ),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "and as assert async await break class continue def del elif else except finally for from global if import in " +
                    "is lambda nonlocal not or pass raise return try while with yield match case",
            ),
            literals = words("True False None self cls"),
            types = words("int str float bool list dict set tuple bytes object complex frozenset bytearray"),
            builtins = words(
                "print len range enumerate zip map filter sorted reversed sum min max abs open isinstance issubclass super " +
                    "property staticmethod classmethod iter next any all type input repr format hasattr getattr setattr id hash " +
                    "round divmod pow chr ord vars dir help",
            ),
            capitalizedTypes = true,
        )
        "ruby" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "^=begin[\\s\\S]*?(?:^=end|\\z)"), Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Str, "\"(?:\\\\.|#\\{[^}\\n]*\\}|[^\"\\\\])*\""), Rule(CodeToken.Str, SQ),
                Rule(CodeToken.Literal, "(?<!:):[A-Za-z_]\\w*[?!]?"),
                Rule(CodeToken.Variable, "@@?[A-Za-z_]\\w*|\\$[A-Za-z_]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo " +
                    "rescue retry return super then undef unless until when while yield require require_relative include " +
                    "extend attr_accessor attr_reader attr_writer private protected public lambda proc",
            ),
            literals = words("true false nil self"),
            builtins = words("puts print p raise loop"),
            capitalizedTypes = true,
            identifier = "[\\p{L}_][\\p{L}\\p{N}_]*[?!]?",
        )
        "php" -> Grammar(
            listOf(
                Rule(CodeToken.Meta, "<\\?(?:php|=)?|\\?>"),
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Meta, "#\\[[^\\]\\n]*\\]"), Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Variable, "\\$[A-Za-z_]\\w*"),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ), Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "abstract and array as break callable case catch class clone const continue declare default do echo else elseif " +
                    "empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach " +
                    "function global goto if implements include include_once instanceof insteadof interface isset list match " +
                    "namespace new or print private protected public readonly require require_once return static switch throw " +
                    "trait try unset use var while xor yield",
            ),
            literals = words("true false null TRUE FALSE NULL"),
            types = words("int float string bool void mixed never object iterable"),
            capitalizedTypes = true,
        )
        "bash" -> Grammar(
            listOf(
                Rule(CodeToken.Meta, "^#!.*"),
                Rule(CodeToken.Comment, "(?<=^|[\\s;|&(])#.*"),
                Rule(CodeToken.Str, "\"(?:\\\\.|[^\"\\\\])*\""), Rule(CodeToken.Str, "\\$?'[^']*'"),
                Rule(CodeToken.Variable, "\\$(?:\\{[^}\\n]*\\}|[A-Za-z_]\\w*|[0-9@#?*!$-])"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "if then else elif fi for while until do done case esac in function select time return local export readonly " +
                    "declare typeset unset break continue exit source alias set shift trap eval exec",
            ),
            builtins = words(
                "echo printf cd pwd ls cat grep sed awk find xargs sort uniq head tail wc cut tr tee mkdir rm cp mv touch chmod " +
                    "chown ln curl wget git npm npx node python python3 pip cargo make docker kubectl ssh scp tar gzip unzip test " +
                    "read sudo brew yarn pnpm go rustc swift xcodebuild gradle java adb which env",
            ),
            identifier = "[\\p{L}_][\\p{L}\\p{N}_-]*",
        )
        "powershell" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "<#[\\s\\S]*?(?:#>|\\z)"), Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Str, "\"(?:`.|[^\"`])*\""), Rule(CodeToken.Str, "'(?:''|[^'])*'"),
                Rule(CodeToken.Variable, "\\$(?:\\{[^}\\n]*\\}|[\\w:]+)"),
                Rule(CodeToken.Builtin, "\\b[A-Za-z]+-[A-Za-z]+\\b"),
                Rule(CodeToken.Property, "(?<=\\s)-[A-Za-z]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "begin break catch class continue data default do dynamicparam else elseif end enum exit filter finally for " +
                    "foreach from function if in param process return switch throw trap try until using var while workflow",
            ),
            ignoreCase = true,
        )
        "json" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Property, DQ + "(?=\\s*:)"), Rule(CodeToken.Str, DQ),
                Rule(CodeToken.Property, "[A-Za-z_$][\\w$]*(?=\\s*:)"), Rule(CodeToken.Str, SQ),
                Rule(CodeToken.Number, NUMBER),
            ),
            literals = words("true false null NaN Infinity"),
        )
        "yaml" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "(?<=^|\\s)#.*"),
                Rule(CodeToken.Meta, "^(?:---|\\.\\.\\.)(?=\\s|$)"),
                Rule(CodeToken.Property, "(?:" + DQ + "|" + SQ + ")(?=\\s*:(?:\\s|$))"),
                Rule(CodeToken.Property, "(?<=^[ \\t]{0,40}(?:- ){0,4})[^\\s#:\"'\\[\\]{},][^#:\\n]*?(?=\\s*:(?:[ \\t]|$))"),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ),
                Rule(CodeToken.Variable, "[&*][\\w-]+"), Rule(CodeToken.Meta, "!!?[\\w/]+"),
                Rule(CodeToken.Number, NUMBER),
            ),
            literals = words("true false null yes no on off True False Null"),
        )
        "toml" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Section, "^[ \\t]*\\[\\[?[^\\]\\n]*\\]\\]?"),
                Rule(CodeToken.Property, "^[ \\t]*[\\w.\"'-]+(?=\\s*=)"),
                Rule(CodeToken.Str, TRIPLE_DQ), Rule(CodeToken.Str, TRIPLE_SQ), Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, "'[^'\\n]*'"),
                Rule(CodeToken.Number, "\\d{4}-\\d{2}-\\d{2}(?:[Tt ]\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?(?:Z|[+-]\\d{2}:\\d{2})?)?"),
                Rule(CodeToken.Number, NUMBER),
            ),
            literals = words("true false inf nan"),
        )
        "ini" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "^[ \\t]*[#;!].*"),
                Rule(CodeToken.Section, "^[ \\t]*\\[[^\\]\\n]*\\]"),
                Rule(CodeToken.Property, "^[ \\t]*[^\\s=:#;\\[][^=:\\n]*?(?=\\s*[=:])"),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ), Rule(CodeToken.Number, NUMBER),
            ),
            literals = words("true false yes no on off"),
        )
        "sql" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "--.*"), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, "'(?:''|[^'])*'"), Rule(CodeToken.Property, "\"(?:\"\"|[^\"])*\"|`[^`]*`"),
                Rule(CodeToken.Variable, "(?<![\\w:])[@:][A-Za-z_]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "select from where and or not insert into values update set delete create table drop alter add column index view " +
                    "join inner left right full outer cross on as group by order having limit offset union all distinct case when " +
                    "then else end is like in between exists primary key foreign references default unique check constraint if " +
                    "begin commit rollback transaction with returning asc desc database schema grant revoke trigger procedure " +
                    "function return returns declare replace explain analyze using natural over partition window cascade truncate",
            ),
            literals = words("null true false"),
            types = words(
                "int integer bigint smallint tinyint serial bigserial decimal numeric real float double precision varchar char " +
                    "text boolean bool date time timestamp timestamptz interval json jsonb uuid blob bytea",
            ),
            builtins = words("count sum avg min max coalesce now lower upper length substring cast round abs"),
            ignoreCase = true,
        )
        "html" -> {
            val tag = Grammar(
                listOf(
                    Rule(CodeToken.Tag, "(?<=<|</)[A-Za-z][\\w:.-]*"),
                    Rule(CodeToken.Str, "\"[^\"]*\"|'[^']*'"),
                    Rule(CodeToken.Property, "[A-Za-z_:@][\\w:.-]*"),
                ),
                identifier = null,
            )
            Grammar(
                listOf(
                    Rule(CodeToken.Comment, "<!--[\\s\\S]*?(?:-->|\\z)"),
                    Rule(CodeToken.Str, "<!\\[CDATA\\[[\\s\\S]*?(?:\\]\\]>|\\z)"),
                    Rule(CodeToken.Meta, "<![A-Za-z][^>]*>|<\\?[\\s\\S]*?(?:\\?>|\\z)"),
                    Rule(null, "</?[A-Za-z][\\w:.-]*(?:\"[^\"]*\"|'[^']*'|[^'\">])*>?", inside = tag),
                    Rule(CodeToken.Literal, "&(?:#\\d+|#x[0-9a-fA-F]+|\\w+);"),
                ),
                identifier = null,
            )
        }
        "css" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, "url\\([^)\\n]*\\)"),
                Rule(CodeToken.Comment, "(?<![:\\w])//.*"),
                Rule(CodeToken.Keyword, "@[\\w-]+|!important"),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ),
                Rule(CodeToken.Number, "#[0-9a-fA-F]{3,8}\\b"),
                Rule(CodeToken.Variable, "\\$[\\w-]+|--[\\w-]+"),
                Rule(CodeToken.Property, "[\\w-]+(?=\\s*:[^{};]*[;}])"),
                Rule(CodeToken.Type, "[.#][A-Za-z_-][\\w-]*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            literals = words("inherit initial unset none auto transparent currentColor"),
            identifier = "-?[\\p{L}_][\\p{L}\\p{N}_-]*",
        )
        "diff" -> Grammar(
            listOf(
                Rule(CodeToken.Meta, "^(?:diff|index|---|\\+\\+\\+) .*|^(?:---|\\+\\+\\+)$"),
                Rule(CodeToken.Section, "^@@.*"),
                Rule(CodeToken.Inserted, "^[+>].*"),
                Rule(CodeToken.Deleted, "^[-<].*"),
            ),
            identifier = null,
        )
        "markdown" -> Grammar(
            listOf(
                Rule(CodeToken.Str, "^[ \\t]*(?:```|~~~)[\\s\\S]*?(?:^[ \\t]*(?:```|~~~)|\\z)"),
                Rule(CodeToken.Section, "^#{1,6}[ \\t].*"),
                Rule(CodeToken.Comment, "^[ \\t]*>.*"),
                Rule(CodeToken.Keyword, "^[ \\t]*(?:[-*+]|\\d+[.)])(?=[ \\t])"),
                Rule(CodeToken.Str, "`[^`\\n]+`"),
                Rule(CodeToken.Property, "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"),
            ),
            identifier = null,
        )
        "dockerfile" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "^[ \\t]*#.*"),
                Rule(
                    CodeToken.Keyword,
                    "(?i)^[ \\t]*(?:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|" +
                        "ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\\b|\\bAS\\b",
                ),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ),
                Rule(CodeToken.Variable, "\\$\\{[^}\\n]*\\}|\\$[A-Za-z_]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
        )
        "makefile" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Variable, "\\$[({][^)}\\n]*[)}]|\\$[@<^*?%+|]"),
                Rule(CodeToken.Section, "^[^\\s:#=][^:#=\\n]*?(?=:(?!=))"),
                Rule(CodeToken.Property, "^[ \\t]*[\\w.-]+(?=\\s*(?:[:+?!]?=))"),
                Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ),
            ),
            keywords = words("include ifeq ifneq ifdef ifndef else endif define endef export override unexport vpath"),
        )
        "lua" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, "--\\[\\[[\\s\\S]*?(?:\\]\\]|\\z)"), Rule(CodeToken.Comment, "--.*"),
                Rule(CodeToken.Str, "\\[\\[[\\s\\S]*?(?:\\]\\]|\\z)"), Rule(CodeToken.Str, DQ), Rule(CodeToken.Str, SQ),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words("and break do else elseif end for function goto if in local not or repeat return then until while"),
            literals = words("nil true false self"),
            builtins = words(
                "print pairs ipairs require type tostring tonumber table string math os io error assert pcall select " +
                    "setmetatable getmetatable unpack next rawget rawset",
            ),
        )
        "dart" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, "r?" + TRIPLE_DQ), Rule(CodeToken.Str, "r?" + TRIPLE_SQ),
                Rule(CodeToken.Str, DQ_TEMPLATED), Rule(CodeToken.Str, "'(?:\\\\.|\\$\\{[^}\\n]*\\}|[^'\\\\\\n])*'"),
                Rule(CodeToken.Meta, ANNOTATION), Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "abstract as assert async await base break case catch class const continue covariant default deferred do " +
                    "dynamic else enum export extends extension external factory final finally for get hide if implements " +
                    "import in interface is late library mixin new of on operator part required rethrow return sealed set show " +
                    "static switch sync throw try typedef var when while with yield",
            ),
            literals = words("true false null this super"),
            types = words("int double num bool void dynamic"),
            capitalizedTypes = true,
        )
        "scala" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, LINE_COMMENT), Rule(CodeToken.Comment, BLOCK_COMMENT),
                Rule(CodeToken.Str, "[a-z]?" + TRIPLE_DQ), Rule(CodeToken.Str, "[a-z]?" + DQ_TEMPLATED), Rule(CodeToken.Str, CHAR),
                Rule(CodeToken.Meta, ANNOTATION), Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "abstract case catch class def do else enum export extends final finally for forSome given if implicit import " +
                    "lazy match new object override package private protected return sealed then throw trait try type using val " +
                    "var while with yield extension inline opaque transparent derives end",
            ),
            literals = words("true false null this super Nil None"),
            capitalizedTypes = true,
        )
        "graphql" -> Grammar(
            listOf(
                Rule(CodeToken.Comment, HASH_COMMENT),
                Rule(CodeToken.Str, TRIPLE_DQ), Rule(CodeToken.Str, DQ),
                Rule(CodeToken.Variable, "\\$[A-Za-z_]\\w*"), Rule(CodeToken.Meta, "@[A-Za-z_]\\w*"),
                Rule(CodeToken.Number, NUMBER),
            ),
            keywords = words(
                "query mutation subscription fragment on type input enum interface union schema scalar directive extend " +
                    "implements repeatable",
            ),
            literals = words("true false null"),
            capitalizedTypes = true,
        )
        else -> error("no grammar for $id")
    }

    class Rule(val token: CodeToken?, val pattern: String, val inside: Grammar? = null)

    /**
     * One language: [rules] in priority order, joined into one alternation with the identifier rule last. A rule with
     * [Rule.inside] hands its match to that grammar (markup tags); the rest of a match keeps the code colour.
     */
    class Grammar(
        private val rules: List<Rule>,
        private val keywords: Set<String> = emptySet(),
        private val literals: Set<String> = emptySet(),
        private val types: Set<String> = emptySet(),
        private val builtins: Set<String> = emptySet(),
        private val capitalizedTypes: Boolean = false,
        private val ignoreCase: Boolean = false,
        identifier: String? = IDENT,
    ) {
        private val pattern: Pattern
        private val groups: IntArray
        private val identifierGroup: Int
        private val lowerKeywords = if (ignoreCase) keywords.map { it.lowercase() }.toSet() else keywords
        private val lowerLiterals = if (ignoreCase) literals.map { it.lowercase() }.toSet() else literals
        private val lowerTypes = if (ignoreCase) types.map { it.lowercase() }.toSet() else types
        private val lowerBuiltins = if (ignoreCase) builtins.map { it.lowercase() }.toSet() else builtins

        init {
            val parts = rules.map { it.pattern } + listOfNotNull(identifier)
            val starts = IntArray(parts.size)
            var group = 1
            for ((index, part) in parts.withIndex()) {
                starts[index] = group
                group += 1 + Pattern.compile(part).matcher("").groupCount()
            }
            groups = starts
            identifierGroup = if (identifier != null) starts.last() else -1
            pattern = Pattern.compile(parts.joinToString("|") { "($it)" }, Pattern.MULTILINE)
        }

        fun tokenize(code: String, from: Int, to: Int, out: MutableList<CodeSpan>) {
            val matcher = pattern.matcher(code)
            matcher.region(from, to)
            matcher.useTransparentBounds(true)
            matcher.useAnchoringBounds(false)
            var position = from
            while (position < to && matcher.find()) {
                val start = matcher.start()
                val end = matcher.end()
                if (end <= start) {
                    position = start + 1
                    if (position >= to) break
                    matcher.region(position, to)
                    continue
                }
                position = end
                if (identifierGroup > 0 && matcher.start(identifierGroup) >= 0) {
                    classify(code, start, end, to)?.let { out += CodeSpan(start, end, it) }
                    continue
                }
                val rule = rules.indices.firstOrNull { matcher.start(groups[it]) >= 0 }?.let { rules[it] } ?: continue
                val inside = rule.inside
                if (inside != null) {
                    inside.tokenize(code, start, end, out)
                } else if (rule.token != null) {
                    out += CodeSpan(start, end, rule.token)
                }
            }
        }

        private fun classify(code: String, start: Int, end: Int, limit: Int): CodeToken? {
            val word = code.substring(start, end)
            val key = if (ignoreCase) word.lowercase() else word
            return when {
                key in lowerKeywords -> CodeToken.Keyword
                key in lowerLiterals -> CodeToken.Literal
                key in lowerTypes -> CodeToken.Type
                key in lowerBuiltins -> CodeToken.Builtin
                nextNonBlank(code, end, limit) == '(' -> CodeToken.Function
                capitalizedTypes && word[0].isUpperCase() && word.any { it.isLowerCase() } -> CodeToken.Type
                else -> null
            }
        }

        private fun nextNonBlank(code: String, from: Int, limit: Int): Char? {
            var k = from
            while (k < limit && (code[k] == ' ' || code[k] == '\t')) k++
            return if (k < limit) code[k] else null
        }
    }
}
