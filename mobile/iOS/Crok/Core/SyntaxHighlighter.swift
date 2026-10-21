import Foundation

/// Token classes of the code highlighter (relay/DESIGN.md §5 "Replies in Markdown"); `Theme.syntax` colours them.
enum CodeToken: String, Sendable, CaseIterable {
    case comment, keyword, string, number, literal, function, type, builtin, property, tag, variable, meta, regex
    case inserted, deleted, section
}

/// A highlighted range of the code, in UTF-16 offsets (NSString ranges).
struct HighlightRun: Equatable, Sendable {
    let location: Int
    let length: Int
    let token: CodeToken
}

/// A small highlighter for fenced code: per language, a list of regex rules run as one alternation (the first rule
/// that matches at a position wins), then identifiers classified by keyword sets. Only a fence that names a language
/// it knows is highlighted; nothing is guessed. Android has the same design (`SyntaxHighlighter.kt`).
enum SyntaxHighlighter {
    static func highlight(_ code: String, language: String?) -> [HighlightRun] {
        guard let grammar = grammar(for: language) else { return [] }
        let text = code as NSString
        var runs: [HighlightRun] = []
        grammar.tokenize(text, range: NSRange(location: 0, length: text.length), into: &runs)
        return runs
    }

    /// Whether a fence's language is one the highlighter knows.
    static func knows(_ language: String?) -> Bool { grammar(for: language) != nil }

    static func grammar(for language: String?) -> Grammar? {
        guard let language else { return nil }
        let name = language.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "swift": return Grammars.swift
        case "kotlin", "kt", "kts": return Grammars.kotlin
        case "java": return Grammars.java
        case "rust", "rs": return Grammars.rust
        case "go", "golang": return Grammars.go
        case "c", "h": return Grammars.c
        case "cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c", "m", "mm": return Grammars.cpp
        case "csharp", "cs", "c#": return Grammars.csharp
        case "javascript", "js", "jsx", "mjs", "cjs": return Grammars.javascript
        case "typescript", "ts", "tsx", "mts": return Grammars.typescript
        case "python", "py", "python3": return Grammars.python
        case "ruby", "rb": return Grammars.ruby
        case "php": return Grammars.php
        case "bash", "sh", "shell", "zsh", "console", "shellsession": return Grammars.bash
        case "powershell", "ps1", "pwsh": return Grammars.powershell
        case "json", "jsonc", "json5": return Grammars.json
        case "yaml", "yml": return Grammars.yaml
        case "toml": return Grammars.toml
        case "ini", "cfg", "conf", "properties": return Grammars.ini
        case "sql": return Grammars.sql
        case "html", "xml", "svg", "plist", "xhtml", "vue": return Grammars.markup
        case "css": return Grammars.css
        case "scss", "less": return Grammars.scss
        case "diff", "patch": return Grammars.diff
        case "markdown", "md": return Grammars.markdown
        case "dockerfile", "docker": return Grammars.dockerfile
        case "makefile", "make", "mk": return Grammars.makefile
        case "lua": return Grammars.lua
        case "dart": return Grammars.dart
        case "scala": return Grammars.scala
        case "graphql", "gql": return Grammars.graphql
        default: return nil
        }
    }

    /// Every alias the highlighter answers to (for tests).
    static let aliases = [
        "swift", "kotlin", "kt", "kts", "java", "rust", "rs", "go", "golang", "c", "h", "cpp", "c++", "cc", "cxx", "hpp",
        "objc", "objective-c", "m", "mm", "csharp", "cs", "c#", "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts",
        "tsx", "mts", "python", "py", "python3", "ruby", "rb", "php", "bash", "sh", "shell", "zsh", "console",
        "shellsession", "powershell", "ps1", "pwsh", "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "properties", "sql", "html", "xml", "svg", "plist", "xhtml", "vue", "css", "scss", "less", "diff", "patch",
        "markdown", "md", "dockerfile", "docker", "makefile", "make", "mk", "lua", "dart", "scala", "graphql", "gql",
    ]
}

/// One language: ordered rules plus identifier classification. Immutable once built, so it is shared freely.
final class Grammar: @unchecked Sendable {
    struct Rule: Sendable {
        /// Nil for a rule that only exists to tokenize its match with `inside`.
        let token: CodeToken?
        /// A regex without capturing groups (use `(?:…)`); `^` and `$` match at line breaks.
        let pattern: String
        let inside: Grammar?

        init(_ token: CodeToken?, _ pattern: String, inside: Grammar? = nil) {
            self.token = token
            self.pattern = pattern
            self.inside = inside
        }
    }

    let name: String
    let rules: [Rule]
    let keywords: Set<String>
    let literals: Set<String>
    let types: Set<String>
    let builtins: Set<String>
    let caseInsensitive: Bool
    let capitalizedTypes: Bool
    let functionCalls: Bool
    let hasIdentifiers: Bool
    /// Nil only if a pattern failed to compile (tests make sure none does).
    let regex: NSRegularExpression?

    init(
        _ name: String, rules: [Rule], keywords: String = "", literals: String = "", types: String = "", builtins: String = "",
        identifier: String? = #"[A-Za-z_][A-Za-z0-9_]*"#, caseInsensitive: Bool = false, capitalizedTypes: Bool = false,
        functionCalls: Bool = true
    ) {
        func words(_ list: String) -> Set<String> {
            Set(list.split(separator: " ").map { caseInsensitive ? $0.lowercased() : String($0) })
        }
        self.name = name
        self.rules = rules
        self.keywords = words(keywords)
        self.literals = words(literals)
        self.types = words(types)
        self.builtins = words(builtins)
        self.caseInsensitive = caseInsensitive
        self.capitalizedTypes = capitalizedTypes
        self.functionCalls = functionCalls
        self.hasIdentifiers = identifier != nil
        var alternatives = rules.map { "(\($0.pattern))" }
        if let identifier { alternatives.append("(\(identifier))") }
        regex = try? NSRegularExpression(pattern: alternatives.joined(separator: "|"), options: [.anchorsMatchLines])
    }

    func tokenize(_ text: NSString, range: NSRange, into runs: inout [HighlightRun]) {
        guard let regex else { return }
        let string = text as String
        let identifierGroup = rules.count + 1
        regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            for group in 1...(hasIdentifiers ? identifierGroup : rules.count) {
                let matched = match.range(at: group)
                guard matched.location != NSNotFound else { continue }
                guard matched.length > 0 else { return }
                if group == identifierGroup {
                    if let token = classify(text.substring(with: matched), in: text, after: NSMaxRange(matched)) {
                        runs.append(HighlightRun(location: matched.location, length: matched.length, token: token))
                    }
                } else {
                    let rule = rules[group - 1]
                    if let inside = rule.inside {
                        inside.tokenize(text, range: matched, into: &runs)
                    } else if let token = rule.token {
                        runs.append(HighlightRun(location: matched.location, length: matched.length, token: token))
                    }
                }
                return
            }
        }
    }

    private func classify(_ word: String, in text: NSString, after end: Int) -> CodeToken? {
        let key = caseInsensitive ? word.lowercased() : word
        if keywords.contains(key) { return .keyword }
        if literals.contains(key) { return .literal }
        if types.contains(key) { return .type }
        if builtins.contains(key) { return .builtin }
        if functionCalls {
            var i = end
            while i < text.length, text.character(at: i) == 0x20 { i += 1 }
            if i < text.length, text.character(at: i) == 0x28 { return .function }  // "("
        }
        if capitalizedTypes, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
            word.unicodeScalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) })
        {
            return .type
        }
        return nil
    }
}

// MARK: - Grammars

/// Shared pieces of the grammars.
private enum P {
    static let lineComment = #"//[^\n]*"#
    static let blockComment = #"/\*[\s\S]*?(?:\*/|\z)"#
    static let hashComment = #"#[^\n]*"#
    static let doubleQuoted = #""(?:[^"\\\n]|\\.)*"?"#
    static let singleQuoted = #"'(?:[^'\\\n]|\\.)*'?"#
    static let tripleDouble = #""""[\s\S]*?(?:"""|\z)"#
    static let tripleSingle = #"'''[\s\S]*?(?:'''|\z)"#
    static let backtick = #"`(?:[^`\\]|\\[\s\S])*`?"#
    static let number = #"\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[A-Za-z_]?\w*"#
    static let annotation = #"@[A-Za-z_][\w.]*"#
    static let cPreprocessor = #"^[ \t]*#[ \t]*[A-Za-z]+[^\n]*"#

    static func after(_ keywords: String, _ token: CodeToken, name: String = #"[A-Za-z_]\w*"#) -> Grammar.Rule {
        Grammar.Rule(token, "(?<=\\b(?:\(keywords)) )\(name)")
    }
}

enum Grammars {
    typealias R = Grammar.Rule

    static let swift = Grammar(
        "swift",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, P.tripleDouble),
            R(.string, ##"#+"(?:[^"\n]|"(?!#))*"#+"##), R(.string, P.doubleQuoted),
            R(.meta, #"@[A-Za-z_]\w*"#),
            R(.meta, #"#(?:if|elseif|else|endif|available|unavailable|selector|keyPath|file|fileID|filePath|line|column|function|warning|error|sourceLocation|Preview|externalMacro)\b"#),
            P.after("func", .function), P.after("struct|class|enum|protocol|extension|actor|typealias", .type),
            R(.number, P.number),
        ],
        keywords: "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws actor some any nonisolated isolated consuming borrowing mutating nonmutating override final lazy weak unowned convenience required dynamic optional indirect willSet didSet macro package",
        literals: "true false nil self Self super",
        types: "Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat String Character Bool Void Any AnyObject Never",
        capitalizedTypes: true)

    static let kotlin = Grammar(
        "kotlin",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, P.tripleDouble), R(.string, P.doubleQuoted),
            R(.string, P.singleQuoted), R(.meta, #"@[A-Za-z_][\w.:]*"#), P.after("fun", .function),
            P.after("class|interface|object|typealias", .type), R(.number, P.number),
        ],
        keywords: "package import class interface fun val var object companion data sealed enum annotation open abstract override private protected public internal inline suspend operator infix tailrec when if else for while do return break continue throw try catch finally is in as typealias constructor init by lateinit const vararg reified crossinline noinline external expect actual where out value",
        literals: "true false null this super",
        types: "Int Long Short Byte Double Float Boolean Char String Unit Any Nothing",
        capitalizedTypes: true)

    static let java = Grammar(
        "java",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, P.tripleDouble), R(.string, P.doubleQuoted),
            R(.string, P.singleQuoted), R(.meta, P.annotation), P.after("class|interface|enum|record", .type),
            R(.number, P.number),
        ],
        keywords: "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized throw throws transient try volatile while record sealed permits yield var",
        literals: "true false null this super",
        types: "boolean byte char short int long float double void",
        capitalizedTypes: true)

    static let rust = Grammar(
        "rust",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.meta, #"#!?\[[^\]\n]*\]"#),
            R(.string, ##"b?r#+"[\s\S]*?"#+|b?r"[^"]*"?"##), R(.string, #"b?"(?:[^"\\]|\\[\s\S])*"?"#),
            R(.string, #"b?'(?:[^'\\\n]|\\(?:x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]{1,6}\}|.))'"#),
            R(.variable, #"'[A-Za-z_]\w*\b(?!')"#), R(.function, #"\b[A-Za-z_]\w*!(?=\s*[(\[{])"#),
            P.after("fn", .function), P.after("struct|enum|trait|type|impl|union", .type), R(.number, P.number),
        ],
        keywords: "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct trait type unsafe use where while macro_rules union yield",
        literals: "true false self Self super",
        types: "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str",
        capitalizedTypes: true)

    static let go = Grammar(
        "go",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, #"`[^`]*`?"#), R(.string, P.doubleQuoted),
            R(.string, P.singleQuoted), Grammar.Rule(.function, #"(?<=\bfunc \([^)\n]{0,40}\) )[A-Za-z_]\w*"#),
            P.after("func", .function), P.after("type", .type), R(.number, P.number),
        ],
        keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        literals: "true false nil iota",
        types: "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable",
        builtins: "append cap clear close complex copy delete imag len make max min new panic print println real recover")

    private static let cKeywords =
        "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local"
    private static let cTypes =
        "void char short int long float double signed unsigned bool _Bool size_t ssize_t ptrdiff_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t FILE"

    static let c = Grammar(
        "c",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.meta, P.cPreprocessor), R(.string, P.doubleQuoted),
            R(.string, P.singleQuoted), R(.number, P.number),
        ],
        keywords: cKeywords, literals: "true false NULL", types: cTypes)

    static let cpp = Grammar(
        "cpp",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.meta, P.cPreprocessor),
            R(.string, #"@?"(?:[^"\\\n]|\\.)*"?"#), R(.string, P.singleQuoted), R(.meta, #"@[A-Za-z]+"#),
            P.after("class|struct|enum|namespace|union", .type), R(.number, P.number),
        ],
        keywords: cKeywords
            + " alignas alignof and asm catch class concept consteval constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast requires static_assert static_cast template thread_local throw try typeid typename using virtual xor override final",
        literals: "true false nullptr NULL nil Nil YES NO this self super",
        types: cTypes + " wchar_t char8_t char16_t char32_t id instancetype",
        builtins: "std",
        capitalizedTypes: true)

    static let csharp = Grammar(
        "csharp",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.meta, #"^[ \t]*#[ \t]*[a-z]+[^\n]*"#),
            R(.string, #"\$?@"(?:[^"]|"")*"?"#), R(.string, #"\$?"(?:[^"\\\n]|\\.)*"?"#), R(.string, P.singleQuoted),
            P.after("class|struct|interface|enum|record", .type), R(.number, P.number),
        ],
        keywords: "abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch throw try typeof unchecked unsafe using virtual volatile while async await var record init get set yield where when nameof",
        literals: "true false null this",
        types: "bool byte char decimal double float int long object sbyte short string uint ulong ushort void dynamic nint nuint",
        capitalizedTypes: true)

    private static let jsRules: [R] = [
        R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, P.backtick), R(.string, P.doubleQuoted),
        R(.string, P.singleQuoted),
        R(.regex, #"(?<=[=(,:;!&|?{}\[\n]|\breturn)[ \t]*/(?![*/])(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n\[])+/[dgimsuyv]*"#),
        R(.meta, P.annotation), P.after("function", .function, name: #"[A-Za-z_$][\w$]*"#),
        P.after("class|interface|type|enum", .type, name: #"[A-Za-z_$][\w$]*"#), R(.number, P.number),
    ]
    private static let jsKeywords =
        "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch throw try typeof var void while with yield async await of static get set from as"
    private static let jsBuiltins =
        "console Math JSON Promise Array Object String Number Boolean Map Set WeakMap Date RegExp Error Symbol BigInt window document globalThis require module exports process"

    static let javascript = Grammar(
        "javascript", rules: jsRules, keywords: jsKeywords, literals: "true false null undefined NaN Infinity this",
        builtins: jsBuiltins, identifier: #"[A-Za-z_$][\w$]*"#, capitalizedTypes: true)

    static let typescript = Grammar(
        "typescript", rules: jsRules,
        keywords: jsKeywords
            + " interface type enum implements namespace declare abstract private protected public readonly keyof infer is satisfies module unique override asserts",
        literals: "true false null undefined NaN Infinity this",
        types: "string number boolean any unknown never void object bigint symbol", builtins: jsBuiltins,
        identifier: #"[A-Za-z_$][\w$]*"#, capitalizedTypes: true)

    static let python = Grammar(
        "python",
        rules: [
            R(.comment, P.hashComment), R(.string, #"(?i:[rbuf]{0,2})"""[\s\S]*?(?:"""|\z)"#),
            R(.string, #"(?i:[rbuf]{0,2})'''[\s\S]*?(?:'''|\z)"#), R(.string, #"(?i:[rbuf]{0,2})"(?:[^"\\\n]|\\.)*"?"#),
            R(.string, #"(?i:[rbuf]{0,2})'(?:[^'\\\n]|\\.)*'?"#), R(.meta, #"^[ \t]*@[\w.]+"#), P.after("def", .function),
            P.after("class", .type), R(.number, P.number),
        ],
        keywords: "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
        literals: "True False None",
        builtins: "print len range int str float list dict set tuple bool type object isinstance issubclass enumerate zip map filter sorted reversed sum min max abs any all open super iter next repr hash id input format getattr setattr hasattr property staticmethod classmethod",
        capitalizedTypes: true)

    static let ruby = Grammar(
        "ruby",
        rules: [
            R(.comment, #"^=begin[\s\S]*?(?:^=end|\z)"#), R(.comment, P.hashComment), R(.string, P.doubleQuoted),
            R(.string, P.singleQuoted), R(.literal, #"(?<!:):[A-Za-z_]\w*[?!]?"#), R(.property, #"\b[a-z_]\w*:(?=\s)"#),
            R(.variable, #"@@?[A-Za-z_]\w*|\$[A-Za-z_]\w*"#), P.after("def", .function, name: #"(?:self\.)?[A-Za-z_]\w*[?!=]?"#),
            P.after("class|module", .type), R(.number, P.number),
        ],
        keywords: "alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private protected public raise lambda proc loop",
        literals: "true false nil self __FILE__ __LINE__",
        capitalizedTypes: true)

    static let php = Grammar(
        "php",
        rules: [
            R(.meta, #"<\?(?:php|=)?|\?>"#), R(.comment, P.lineComment), R(.comment, P.blockComment), R(.comment, P.hashComment),
            R(.variable, #"\$[A-Za-z_]\w*"#), R(.string, P.doubleQuoted), R(.string, P.singleQuoted),
            P.after("function", .function), P.after("class|interface|trait|enum", .type), R(.number, P.number),
        ],
        keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield",
        literals: "true false null self parent",
        caseInsensitive: true, capitalizedTypes: true)

    static let bash = Grammar(
        "bash",
        rules: [
            R(.meta, #"^#![^\n]*"#), R(.comment, #"(?:^|(?<=[ \t;|&(]))#[^\n]*"#), R(.string, #"\$'(?:[^'\\]|\\.)*'?"#),
            R(.string, #""(?:[^"\\]|\\[\s\S])*"?"#), R(.string, #"'[^']*'?"#),
            R(.variable, #"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[0-9@#?$!*-]"#), R(.number, #"\b\d+\b"#),
        ],
        keywords: "if then else elif fi case esac for select while until do done in function time coproc return exit break continue local export readonly declare typeset unset shift source alias set trap eval exec",
        builtins: "echo printf cd pwd read test wait kill jobs ls cat grep sed awk find xargs sort uniq wc head tail cut tr mkdir rmdir rm cp mv chmod chown ln touch curl wget git npm npx node python python3 pip make sudo brew docker kubectl ssh scp tar zip unzip cargo swift xcodebuild xcrun go",
        identifier: #"[A-Za-z_][\w-]*"#)

    static let powershell = Grammar(
        "powershell",
        rules: [
            R(.comment, #"<#[\s\S]*?(?:#>|\z)"#), R(.comment, P.hashComment), R(.string, #"@"[\s\S]*?(?:^"@|\z)"#),
            R(.string, #""(?:[^"`\n]|`.)*"?"#), R(.string, #"'(?:[^'\n]|'')*'?"#), R(.literal, #"\$(?i:true|false|null)\b"#),
            R(.variable, #"\$(?:\{[^}\n]*\}|[A-Za-z_][\w:]*)"#), R(.builtin, #"\b[A-Z][a-z]+-[A-Z][A-Za-z]+\b"#),
            R(.property, #"(?<=\s)-[A-Za-z][\w-]*"#), R(.number, P.number),
        ],
        keywords: "begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow",
        caseInsensitive: true)

    static let json = Grammar(
        "json",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.property, #""(?:[^"\\\n]|\\.)*"(?=\s*:)"#),
            R(.string, P.doubleQuoted), R(.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
        ],
        literals: "true false null", functionCalls: false)

    static let yaml = Grammar(
        "yaml",
        rules: [
            R(.comment, #"(?:^|(?<=\s))#[^\n]*"#), R(.meta, #"^(?:---|\.\.\.)(?=\s|$)"#), R(.string, P.doubleQuoted),
            R(.string, #"'(?:[^'\n]|'')*'?"#), R(.property, #"[A-Za-z0-9_][\w .\/-]*(?=:(?:[ \t]|$))"#),
            R(.variable, #"[&*][A-Za-z0-9_-]+"#), R(.meta, #"![A-Za-z0-9!_\/-]*"#),
            R(.number, #"(?<![\w.])[-+]?(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\w.])"#),
        ],
        literals: "true false null yes no on off True False Null TRUE FALSE NULL Yes No", identifier: #"[A-Za-z_][\w-]*"#,
        functionCalls: false)

    static let toml = Grammar(
        "toml",
        rules: [
            R(.comment, P.hashComment), R(.section, #"^[ \t]*\[\[?[^\]\n]*\]\]?"#),
            R(.property, #"^[ \t]*[A-Za-z0-9_.\-"']+(?=[ \t]*=)"#), R(.string, P.tripleDouble), R(.string, P.tripleSingle),
            R(.string, P.doubleQuoted), R(.string, #"'[^'\n]*'?"#),
            R(.number, #"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?)?"#),
            R(.number, #"[-+]?\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
        ],
        literals: "true false inf nan", functionCalls: false)

    static let ini = Grammar(
        "ini",
        rules: [
            R(.comment, #"^[ \t]*[;#][^\n]*"#), R(.section, #"^[ \t]*\[[^\]\n]*\]"#),
            R(.property, #"^[ \t]*[^\s=:;#\[][^=:\n]*?(?=[ \t]*[=:])"#), R(.string, P.doubleQuoted), R(.string, P.singleQuoted),
            R(.number, #"\b\d+(?:\.\d+)?\b"#),
        ],
        literals: "true false on off yes no", caseInsensitive: true, functionCalls: false)

    static let sql = Grammar(
        "sql",
        rules: [
            R(.comment, #"--[^\n]*"#), R(.comment, P.blockComment), R(.string, #"'(?:[^']|'')*'?"#),
            R(.property, #""(?:[^"]|"")*"|`[^`]*`"#), R(.variable, #"(?<![\w:])[@:][A-Za-z_]\w*"#),
            R(.number, #"\b\d+(?:\.\d+)?\b"#),
        ],
        keywords: "select from where and or not insert into values update set delete create table drop alter add column primary key foreign references index unique default is in like ilike between join inner left right outer full cross on group by order having limit offset distinct as union all exists case when then else end begin commit rollback transaction view trigger function procedure returns return declare if asc desc with recursive cast over partition window returning conflict do nothing replace temporary temp database schema grant revoke use show explain analyze vacuum",
        literals: "true false null",
        types: "int integer bigint smallint tinyint varchar char text boolean bool date time timestamp timestamptz interval numeric decimal real float double precision serial bigserial uuid json jsonb blob bytea",
        builtins: "count sum avg min max coalesce now lower upper length substring concat round abs nullif",
        caseInsensitive: true)

    /// Inside a markup tag: its name, attributes and their values.
    private static let markupTag = Grammar(
        "markup-tag",
        rules: [
            R(.tag, #"^</?[^\s>/]+"#), R(.tag, #"/?>$"#), R(.string, #""[^"]*"|'[^']*'"#), R(.property, #"[^\s=>/"']+"#),
        ],
        identifier: nil)

    static let markup = Grammar(
        "markup",
        rules: [
            R(.comment, #"<!--[\s\S]*?(?:-->|\z)"#), R(.string, #"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"#),
            R(.meta, #"<![A-Za-z][^>]*>?"#), R(.meta, #"<\?[\s\S]*?(?:\?>|\z)"#),
            R(nil, #"</?[A-Za-z][\w:.-]*(?:\s+[^\s=>/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*\s*/?>?"#, inside: markupTag),
            R(.literal, #"&(?:[A-Za-z]+|#\d+|#x[0-9A-Fa-f]+);"#),
        ],
        identifier: nil)

    private static func cssRules(lineComments: Bool) -> [R] {
        var rules: [R] = [R(.comment, P.blockComment)]
        if lineComments { rules.append(R(.comment, #"(?<!:)//[^\n]*"#)) }
        rules += [
            R(.string, P.doubleQuoted), R(.string, P.singleQuoted), R(.keyword, #"@[\w-]+"#), R(.variable, #"\$[\w-]+|--[\w-]+"#),
            R(.number, #"#[0-9a-fA-F]{3,8}\b"#), R(.property, #"(?<![\w-])[\w-]+(?=\s*:(?!:)[^{};\n]*(?:;|\}|$))"#),
            R(.function, #"[.#][A-Za-z_-][\w-]*"#), R(.keyword, #"!important\b"#), R(.keyword, #"::?[A-Za-z-]+"#),
            R(.number, #"-?(?:\d+\.?\d*|\.\d+)(?:%|[a-zA-Z]+)?"#),
        ]
        return rules
    }

    static let css = Grammar("css", rules: cssRules(lineComments: false), identifier: #"-?[A-Za-z_][\w-]*"#)
    static let scss = Grammar("scss", rules: cssRules(lineComments: true), identifier: #"-?[A-Za-z_][\w-]*"#)

    static let diff = Grammar(
        "diff",
        rules: [
            R(.meta, #"^(?:diff --git|index |--- |\+\+\+ |similarity|rename |new file|deleted file|Binary files)[^\n]*"#),
            R(.section, #"^@@[^\n]*"#), R(.inserted, #"^\+[^\n]*"#), R(.deleted, #"^-[^\n]*"#),
            R(.comment, #"^\\ [^\n]*"#),
        ],
        identifier: nil)

    static let markdown = Grammar(
        "markdown",
        rules: [
            R(.section, #"^#{1,6}[ \t][^\n]*"#), R(.string, #"^[ \t]*(?:```|~~~)[^\n]*"#), R(.string, #"`[^`\n]+`"#),
            R(.keyword, #"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"#), R(.comment, #"^[ \t]*>[^\n]*"#),
            R(.property, #"!?\[[^\]\n]*\]\([^)\n]*\)"#),
        ],
        identifier: nil)

    static let dockerfile = Grammar(
        "dockerfile",
        rules: [
            R(.comment, #"^[ \t]*#[^\n]*"#),
            R(.keyword, #"^[ \t]*(?i:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#),
            R(.keyword, #"(?i:\bAS\b)"#), R(.string, P.doubleQuoted), R(.string, P.singleQuoted),
            R(.variable, #"\$\{[^}\n]*\}|\$[A-Za-z_]\w*"#), R(.property, #"(?<=\s)--[\w-]+"#), R(.number, #"\b\d+\b"#),
        ],
        identifier: nil)

    static let makefile = Grammar(
        "makefile",
        rules: [
            R(.comment, P.hashComment),
            R(.keyword, #"^[ \t]*(?:-include|sinclude|include|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|export|unexport|override|vpath)\b"#),
            R(.variable, #"\$\([^)\n]*\)|\$\{[^}\n]*\}|\$[@<^?*%+]"#), R(.property, #"^[A-Za-z_][\w.-]*(?=[ \t]*[+?!:]?=)"#),
            R(.section, #"^[^\s:=#][^:=#\n]*(?=:(?!=))"#), R(.string, P.doubleQuoted), R(.string, P.singleQuoted),
        ],
        identifier: nil)

    static let lua = Grammar(
        "lua",
        rules: [
            R(.comment, #"--\[\[[\s\S]*?(?:\]\]|\z)"#), R(.comment, #"--[^\n]*"#), R(.string, #"\[\[[\s\S]*?(?:\]\]|\z)"#),
            R(.string, P.doubleQuoted), R(.string, P.singleQuoted), P.after("function", .function, name: #"[A-Za-z_][\w.:]*"#),
            R(.number, P.number),
        ],
        keywords: "and break do else elseif end for function goto if in local not or repeat return then until while",
        literals: "true false nil self",
        builtins: "print pairs ipairs table string math os io require type tostring tonumber error assert setmetatable getmetatable select next pcall xpcall unpack rawget rawset coroutine")

    static let dart = Grammar(
        "dart",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, #"r?"""[\s\S]*?(?:"""|\z)"#),
            R(.string, #"r?'''[\s\S]*?(?:'''|\z)"#), R(.string, #"r?"(?:[^"\\\n]|\\.)*"?"#), R(.string, #"r?'(?:[^'\\\n]|\\.)*'?"#),
            R(.meta, P.annotation), P.after("class|mixin|enum|extension|typedef", .type), R(.number, P.number),
        ],
        keywords: "abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync throw try typedef var void when while with yield",
        literals: "true false null this super",
        types: "int double num String bool List Map Set Future Stream Object Never Iterable",
        capitalizedTypes: true)

    static let scala = Grammar(
        "scala",
        rules: [
            R(.comment, P.lineComment), R(.comment, P.blockComment), R(.string, P.tripleDouble), R(.string, P.doubleQuoted),
            R(.string, #"'(?:[^'\\\n]|\\.)'"#), R(.meta, P.annotation), P.after("def", .function),
            P.after("class|trait|object|enum", .type), R(.number, P.number),
        ],
        keywords: "abstract case catch class def do else enum export extends final finally for forSome given if implicit import lazy match new object override package private protected return sealed super then throw trait try type val var while with yield using extension inline opaque derives end",
        literals: "true false null this",
        capitalizedTypes: true)

    static let graphql = Grammar(
        "graphql",
        rules: [
            R(.comment, P.hashComment), R(.string, P.tripleDouble), R(.string, P.doubleQuoted),
            R(.variable, #"\$[A-Za-z_]\w*"#), R(.meta, #"@[A-Za-z_]\w*"#), R(.property, #"\b[A-Za-z_]\w*(?=\s*:)"#),
            R(.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
        ],
        keywords: "query mutation subscription fragment on type interface union enum input scalar schema extend directive implements repeatable",
        literals: "true false null",
        types: "ID String Int Float Boolean",
        capitalizedTypes: true)
}
