import Foundation

// A TOML 1.0 parser that remembers where everything is, and an editor that changes `config.toml`
// by inserting text only. The terminal's importer re-serialises the whole file, which drops
// comments; editing in place keeps every other byte, and a file this parser rejects is never touched.

/// Why a config file cannot be edited.
enum ClaudeTOMLError: Error, CustomStringConvertible {
    /// The file is not valid TOML.
    case syntax(message: String, line: Int, column: Int)
    /// The file is valid, but a table the import writes is in a form that cannot be edited by insertion.
    case unsupportedLayout(String)
    /// A table or key the import writes has the wrong type, as the terminal reports it.
    case type(String)

    var description: String {
        switch self {
        case let .syntax(message, line, column): return "\(message) at line \(line), column \(column)"
        case .unsupportedLayout(let detail): return detail
        case .type(let detail): return detail
        }
    }
}

/// A table in the parsed document, with how it came to exist (which decides what may extend it).
final class ClaudeTOMLTable {
    enum Origin { case root, header, implicit, dotted, inline, arrayElement }
    var origin: Origin
    var entries: [String: ClaudeTOMLEntry] = [:]
    /// The `[header]` line that defined it, for `.header` tables.
    var headerIndex: Int?

    init(_ origin: Origin) { self.origin = origin }
}

enum ClaudeTOMLEntry {
    case table(ClaudeTOMLTable)
    /// `[[array.of.tables]]`.
    case tableArray([ClaudeTOMLTable])
    /// A value; `keyValueIndex` is the statement that defined it when it is not inside an inline table.
    case value(ClaudeTOMLValue, keyValueIndex: Int?)
}

indirect enum ClaudeTOMLValue {
    case string(String)
    case integer
    case float
    case boolean(Bool)
    case datetime
    case array(ClaudeTOMLArray)
    case inlineTable(ClaudeTOMLTable)
}

/// An array literal and the byte offsets needed to append to it.
struct ClaudeTOMLArray {
    var items: [ClaudeTOMLValue] = []
    var itemRanges: [Range<Int>] = []
    var open = 0
    var close = 0
    /// The comma after the last item, when the array has a trailing comma.
    var trailingComma: Int?
}

struct ClaudeTOMLKeyValue {
    let table: ClaudeTOMLTable
    let keys: [String]
    let lineStart: Int
    let valueRange: Range<Int>
    /// Just past the statement's line break (or the end of the file).
    let lineEnd: Int
}

struct ClaudeTOMLHeader {
    let keys: [String]
    let isArray: Bool
    let lineStart: Int
    let lineEnd: Int
}

struct ClaudeTOMLDocument {
    let bytes: [UInt8]
    let root = ClaudeTOMLTable(.root)
    private(set) var headers: [ClaudeTOMLHeader] = []
    private(set) var keyValues: [ClaudeTOMLKeyValue] = []

    init(_ text: String) throws {
        var bytes = [UInt8](text.utf8)
        // A byte-order mark is not content.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        self.bytes = bytes
        var parser = ClaudeTOMLParser(bytes: bytes, root: root)
        try parser.parseDocument()
        headers = parser.headers
        keyValues = parser.keyValues
    }

    /// The offset in the original text of `offset` here (the BOM, if any, was dropped).
    func textOffset(_ offset: Int, in text: String) -> Int { text.utf8.starts(with: [0xEF, 0xBB, 0xBF]) ? offset + 3 : offset }

    /// Just past the last statement of the `[header]` section at `index`, or past the header line.
    func sectionEnd(ofHeader index: Int) -> Int {
        let header = headers[index]
        let next = headers.indices.contains(index + 1) ? headers[index + 1].lineStart : bytes.count
        let last = keyValues.filter { $0.lineStart >= header.lineEnd && $0.lineStart < next }.map(\.lineEnd).max()
        return last ?? header.lineEnd
    }

    /// The indentation of the last statement in a section, so inserted keys line up with it.
    func indentation(ofHeader index: Int) -> String {
        let header = headers[index]
        let next = headers.indices.contains(index + 1) ? headers[index + 1].lineStart : bytes.count
        guard let last = keyValues.last(where: { $0.lineStart >= header.lineEnd && $0.lineStart < next }) else { return "" }
        return String(decoding: bytes[last.lineStart...].prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
    }
}

// MARK: - Parser

private struct ClaudeTOMLParser {
    let bytes: [UInt8]
    let root: ClaudeTOMLTable
    var index = 0
    var headers: [ClaudeTOMLHeader] = []
    var keyValues: [ClaudeTOMLKeyValue] = []
    var current: ClaudeTOMLTable

    init(bytes: [UInt8], root: ClaudeTOMLTable) {
        self.bytes = bytes
        self.root = root
        current = root
    }

    private var atEnd: Bool { index >= bytes.count }
    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    private func peek(_ offset: Int) -> UInt8? { index + offset < bytes.count ? bytes[index + offset] : nil }

    private func fail(_ message: String, at offset: Int? = nil) -> ClaudeTOMLError {
        let offset = min(offset ?? index, bytes.count)
        var line = 1, column = 1
        for byte in bytes[..<offset] {
            if byte == 0x0A { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
        }
        return .syntax(message: message, line: line, column: column)
    }

    private mutating func skipSpaces() { while let byte = peek, byte == 0x20 || byte == 0x09 { index += 1 } }

    /// A comment runs to the end of the line; control characters other than tab are not allowed in it.
    private mutating func skipComment() throws {
        guard peek == UInt8(ascii: "#") else { return }
        while let byte = peek, byte != 0x0A {
            if byte == 0x0D && peek(1) == 0x0A { break }
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F { throw fail("control character in comment") }
            index += 1
        }
    }

    /// Consumes a line break; returns false at the end of the file.
    private mutating func newline() throws -> Bool {
        if atEnd { return false }
        if peek == 0x0A { index += 1; return true }
        if peek == 0x0D && peek(1) == 0x0A { index += 2; return true }
        throw fail("expected newline")
    }

    mutating func parseDocument() throws {
        while !atEnd {
            let lineStart = index
            skipSpaces()
            try skipComment()
            if atEnd { break }
            if peek == 0x0A || peek == 0x0D { _ = try newline(); continue }
            if peek == UInt8(ascii: "[") {
                try header(lineStart: lineStart)
            } else {
                let keys = try dottedKey()
                skipSpaces()
                guard peek == UInt8(ascii: "=") else { throw fail("expected `=` after a key") }
                index += 1
                skipSpaces()
                let valueStart = index
                let value = try self.value(depth: 0)
                let valueEnd = index
                skipSpaces()
                try skipComment()
                _ = try newline()
                keyValues.append(ClaudeTOMLKeyValue(table: current, keys: keys, lineStart: lineStart, valueRange: valueStart..<valueEnd, lineEnd: index))
                try insert(value, at: keys, into: current, keyValueIndex: keyValues.count - 1, keyOffset: lineStart)
            }
        }
    }

    // MARK: Tables

    private mutating func header(lineStart: Int) throws {
        let isArray = peek(1) == UInt8(ascii: "[")
        index += isArray ? 2 : 1
        skipSpaces()
        let keys = try dottedKey()
        skipSpaces()
        guard peek == UInt8(ascii: "]") else { throw fail("expected `]` to close a table header") }
        index += 1
        if isArray {
            guard peek == UInt8(ascii: "]") else { throw fail("expected `]]` to close an array of tables") }
            index += 1
        }
        skipSpaces()
        try skipComment()
        _ = try newline()
        headers.append(ClaudeTOMLHeader(keys: keys, isArray: isArray, lineStart: lineStart, lineEnd: index))

        var table = root
        for key in keys.dropLast() {
            switch table.entries[key] {
            case nil:
                let child = ClaudeTOMLTable(.implicit)
                table.entries[key] = .table(child)
                table = child
            case .table(let child):
                if child.origin == .inline { throw fail("cannot extend an inline table", at: lineStart) }
                table = child
            case .tableArray(let elements):
                guard let last = elements.last else { throw fail("empty array of tables", at: lineStart) }
                table = last
            case .value:
                throw fail("`\(keys.joined(separator: "."))` extends a value that is not a table", at: lineStart)
            }
        }
        guard let last = keys.last else { throw fail("empty table name", at: lineStart) }
        if isArray {
            let element = ClaudeTOMLTable(.arrayElement)
            switch table.entries[last] {
            case nil: table.entries[last] = .tableArray([element])
            case .tableArray(let elements): table.entries[last] = .tableArray(elements + [element])
            default: throw fail("`\(keys.joined(separator: "."))` is already defined and is not an array of tables", at: lineStart)
            }
            current = element
        } else {
            switch table.entries[last] {
            case nil:
                let child = ClaudeTOMLTable(.header)
                child.headerIndex = headers.count - 1
                table.entries[last] = .table(child)
                current = child
            case .table(let child) where child.origin == .implicit:
                // A super-table may be defined after its sub-tables, once.
                child.origin = .header
                child.headerIndex = headers.count - 1
                current = child
            default:
                throw fail("table `\(keys.joined(separator: "."))` is defined more than once", at: lineStart)
            }
        }
    }

    /// Stores `value` at a dotted key path under `table`, creating dotted-key tables on the way.
    private mutating func insert(_ value: ClaudeTOMLValue, at keys: [String], into table: ClaudeTOMLTable, keyValueIndex: Int?, keyOffset: Int) throws {
        var table = table
        for key in keys.dropLast() {
            switch table.entries[key] {
            case nil:
                let child = ClaudeTOMLTable(.dotted)
                table.entries[key] = .table(child)
                table = child
            case .table(let child) where child.origin == .dotted:
                table = child
            default:
                throw fail("duplicate key `\(keys.joined(separator: "."))`", at: keyOffset)
            }
        }
        guard let last = keys.last, table.entries[last] == nil else { throw fail("duplicate key `\(keys.joined(separator: "."))`", at: keyOffset) }
        if case .inlineTable(let inline) = value { table.entries[last] = .table(inline) }
        else { table.entries[last] = .value(value, keyValueIndex: keyValueIndex) }
    }

    // MARK: Keys

    private mutating func dottedKey() throws -> [String] {
        var keys = [try simpleKey()]
        while true {
            let save = index
            skipSpaces()
            guard peek == UInt8(ascii: ".") else { index = save; return keys }
            index += 1
            skipSpaces()
            keys.append(try simpleKey())
        }
    }

    private mutating func simpleKey() throws -> String {
        switch peek {
        case UInt8(ascii: "\""):
            if peek(1) == UInt8(ascii: "\"") && peek(2) == UInt8(ascii: "\"") { throw fail("multi-line strings are not allowed as keys") }
            return try basicString()
        case UInt8(ascii: "'"):
            if peek(1) == UInt8(ascii: "'") && peek(2) == UInt8(ascii: "'") { throw fail("multi-line strings are not allowed as keys") }
            return try literalString()
        default:
            let start = index
            while let byte = peek, ClaudeTOMLParserKey.isBare(byte) { index += 1 }
            guard index > start else { throw fail("expected a key") }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }

    // MARK: Values

    private mutating func value(depth: Int) throws -> ClaudeTOMLValue {
        guard depth < 128 else { throw fail("values are nested too deeply") }
        guard let byte = peek else { throw fail("expected a value") }
        switch byte {
        case UInt8(ascii: "\""):
            if peek(1) == UInt8(ascii: "\"") && peek(2) == UInt8(ascii: "\"") { return .string(try multilineBasicString()) }
            return .string(try basicString())
        case UInt8(ascii: "'"):
            if peek(1) == UInt8(ascii: "'") && peek(2) == UInt8(ascii: "'") { return .string(try multilineLiteralString()) }
            return .string(try literalString())
        case UInt8(ascii: "["): return .array(try array(depth: depth))
        case UInt8(ascii: "{"): return .inlineTable(try inlineTable(depth: depth))
        case UInt8(ascii: "t") where bytes[index...].starts(with: Array("true".utf8)):
            index += 4
            return .boolean(true)
        case UInt8(ascii: "f") where bytes[index...].starts(with: Array("false".utf8)):
            index += 5
            return .boolean(false)
        default: return try scalar()
        }
    }

    /// Whitespace, comments, and line breaks between array items.
    private mutating func skipArraySpace() throws {
        while true {
            skipSpaces()
            try skipComment()
            if peek == 0x0A || (peek == 0x0D && peek(1) == 0x0A) { _ = try newline(); continue }
            return
        }
    }

    private mutating func array(depth: Int) throws -> ClaudeTOMLArray {
        var array = ClaudeTOMLArray()
        array.open = index
        index += 1
        try skipArraySpace()
        while peek != UInt8(ascii: "]") {
            guard !atEnd else { throw fail("unterminated array") }
            let start = index
            array.items.append(try value(depth: depth + 1))
            array.itemRanges.append(start..<index)
            try skipArraySpace()
            if peek == UInt8(ascii: ",") {
                array.trailingComma = index
                index += 1
                try skipArraySpace()
            } else {
                guard peek == UInt8(ascii: "]") else { throw fail("expected `,` or `]` in an array") }
                array.trailingComma = nil
            }
        }
        array.close = index
        index += 1
        return array
    }

    /// TOML 1.1 inline tables (which Grok's parser accepts) may span lines, hold comments, and end with a comma.
    private mutating func inlineTable(depth: Int) throws -> ClaudeTOMLTable {
        let table = ClaudeTOMLTable(.inline)
        index += 1
        while true {
            try skipArraySpace()
            if peek == UInt8(ascii: "}") { index += 1; Self.freeze(table); return table }
            let keyOffset = index
            let keys = try dottedKey()
            skipSpaces()
            guard peek == UInt8(ascii: "=") else { throw fail("expected `=` after a key") }
            index += 1
            skipSpaces()
            let value = try self.value(depth: depth + 1)
            try insert(value, at: keys, into: table, keyValueIndex: nil, keyOffset: keyOffset)
            try skipArraySpace()
            if peek == UInt8(ascii: ",") { index += 1; continue }
            guard peek == UInt8(ascii: "}") else { throw fail("expected `,` or `}` in an inline table") }
        }
    }

    /// Once an inline table closes, nothing may extend it or the tables its dotted keys created.
    private static func freeze(_ table: ClaudeTOMLTable) {
        table.origin = .inline
        for case .table(let child) in table.entries.values { freeze(child) }
    }

    /// Numbers, dates, and times.
    private mutating func scalar() throws -> ClaudeTOMLValue {
        let start = index
        while let byte = peek, ClaudeTOMLParserKey.isBare(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") { index += 1 }
        // A date and a time may be separated by one space.
        if index - start == 10, peek == 0x20, let a = peek(1), let b = peek(2), (48...57).contains(a), (48...57).contains(b), peek(3) == UInt8(ascii: ":") {
            index += 1
            while let byte = peek, ClaudeTOMLParserKey.isBare(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") { index += 1 }
        }
        let token = Array(bytes[start..<index])
        if ClaudeTOMLScalar.isInteger(token) { return .integer }
        if ClaudeTOMLScalar.isFloat(token) { return .float }
        if ClaudeTOMLScalar.isDateTime(token) { return .datetime }
        throw fail(token.isEmpty ? "expected a value" : "invalid value `\(String(decoding: token, as: UTF8.self))`", at: start)
    }

    // MARK: Strings

    private func invalidStringByte(_ byte: UInt8, multiline: Bool) -> Bool {
        if byte == 0x09 { return false }
        if multiline && (byte == 0x0A || byte == 0x0D) { return false }
        return byte < 0x20 || byte == 0x7F
    }

    private mutating func basicString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var chunk = index
        while true {
            guard let byte = peek, byte != 0x0A else { throw fail("unterminated string") }
            if byte == UInt8(ascii: "\"") {
                scalars.append(contentsOf: String(decoding: bytes[chunk..<index], as: UTF8.self).unicodeScalars)
                index += 1
                return String(scalars)
            }
            if byte == UInt8(ascii: "\\") {
                scalars.append(contentsOf: String(decoding: bytes[chunk..<index], as: UTF8.self).unicodeScalars)
                try escape(into: &scalars)
                chunk = index
                continue
            }
            if invalidStringByte(byte, multiline: false) { throw fail("control character in string") }
            index += 1
        }
    }

    private mutating func escape(into scalars: inout String.UnicodeScalarView) throws {
        index += 1
        guard let code = peek else { throw fail("unterminated string") }
        index += 1
        switch code {
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "e"): scalars.append("\u{1B}")
        case UInt8(ascii: "u"), UInt8(ascii: "U"), UInt8(ascii: "x"):
            let count = code == UInt8(ascii: "x") ? 2 : code == UInt8(ascii: "u") ? 4 : 8
            guard index + count <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index..<index + count], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(value) else { throw fail("invalid unicode escape") }
            index += count
            scalars.append(scalar)
        default: throw fail("invalid escape sequence")
        }
    }

    private mutating func multilineBasicString() throws -> String {
        index += 3
        // A line break right after the opening quotes is not part of the string.
        if peek == 0x0A { index += 1 } else if peek == 0x0D && peek(1) == 0x0A { index += 2 }
        var scalars = String.UnicodeScalarView()
        var chunk = index
        while true {
            guard let byte = peek else { throw fail("unterminated multi-line string") }
            if byte == UInt8(ascii: "\"") && peek(1) == UInt8(ascii: "\"") && peek(2) == UInt8(ascii: "\"") {
                // Up to two quotes may sit right before the closing delimiter.
                var quotes = 3
                while quotes < 5 && peek(quotes) == UInt8(ascii: "\"") { quotes += 1 }
                scalars.append(contentsOf: String(decoding: bytes[chunk..<index + quotes - 3], as: UTF8.self).unicodeScalars)
                index += quotes
                return String(scalars)
            }
            if byte == UInt8(ascii: "\\") {
                scalars.append(contentsOf: String(decoding: bytes[chunk..<index], as: UTF8.self).unicodeScalars)
                // A backslash at the end of a line trims the break and the whitespace after it.
                var look = index + 1
                while look < bytes.count && (bytes[look] == 0x20 || bytes[look] == 0x09) { look += 1 }
                if look < bytes.count && (bytes[look] == 0x0A || (bytes[look] == 0x0D && look + 1 < bytes.count && bytes[look + 1] == 0x0A)) {
                    index = look
                    while let next = peek, next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D { index += 1 }
                } else {
                    try escape(into: &scalars)
                }
                chunk = index
                continue
            }
            if byte == 0x0D && peek(1) != 0x0A { throw fail("bare carriage return in string") }
            if invalidStringByte(byte, multiline: true) { throw fail("control character in string") }
            index += 1
        }
    }

    private mutating func literalString() throws -> String {
        index += 1
        let start = index
        while true {
            guard let byte = peek, byte != 0x0A else { throw fail("unterminated string") }
            if byte == UInt8(ascii: "'") {
                let value = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return value
            }
            if invalidStringByte(byte, multiline: false) { throw fail("control character in string") }
            index += 1
        }
    }

    private mutating func multilineLiteralString() throws -> String {
        index += 3
        if peek == 0x0A { index += 1 } else if peek == 0x0D && peek(1) == 0x0A { index += 2 }
        let start = index
        while true {
            guard let byte = peek else { throw fail("unterminated multi-line string") }
            if byte == UInt8(ascii: "'") && peek(1) == UInt8(ascii: "'") && peek(2) == UInt8(ascii: "'") {
                var quotes = 3
                while quotes < 5 && peek(quotes) == UInt8(ascii: "'") { quotes += 1 }
                let value = String(decoding: bytes[start..<index + quotes - 3], as: UTF8.self)
                index += quotes
                return value
            }
            if byte == 0x0D && peek(1) != 0x0A { throw fail("bare carriage return in string") }
            if invalidStringByte(byte, multiline: true) { throw fail("control character in string") }
            index += 1
        }
    }
}

// MARK: - Scalars

/// Validates number, date, and time literals as Grok's TOML parser (TOML 1.1) does, including the
/// ranges: integers must fit 64 bits and dates must exist.
enum ClaudeTOMLScalar {
    private static func isDigit(_ byte: UInt8, radix: Int = 10) -> Bool {
        switch radix {
        case 16: return (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        case 8: return (48...55).contains(byte)
        case 2: return byte == 48 || byte == 49
        default: return (48...57).contains(byte)
        }
    }

    /// Digits with single underscores only between digits.
    private static func digits<C: BidirectionalCollection>(_ bytes: C, radix: Int = 10) -> Bool where C.Element == UInt8 {
        guard let first = bytes.first, let last = bytes.last, isDigit(first, radix: radix), isDigit(last, radix: radix) else { return false }
        var previousUnderscore = false
        for byte in bytes {
            if byte == UInt8(ascii: "_") { if previousUnderscore { return false }; previousUnderscore = true; continue }
            guard isDigit(byte, radix: radix) else { return false }
            previousUnderscore = false
        }
        return true
    }

    private static func stripped<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
    }

    static func isInteger(_ token: [UInt8]) -> Bool {
        if token.count > 2, token[0] == UInt8(ascii: "0") {
            let radix: Int? = token[1] == UInt8(ascii: "x") ? 16 : token[1] == UInt8(ascii: "o") ? 8 : token[1] == UInt8(ascii: "b") ? 2 : nil
            if let radix { return digits(token[2...], radix: radix) && Int64(stripped(token[2...]), radix: radix) != nil }
        }
        let body = token.first == UInt8(ascii: "+") || token.first == UInt8(ascii: "-") ? token.dropFirst() : token[...]
        guard digits(body), body.count == 1 || body.first != UInt8(ascii: "0") else { return false }
        return Int64(stripped(token)) != nil
    }

    static func isFloat(_ token: [UInt8]) -> Bool {
        var body = token[...]
        if body.first == UInt8(ascii: "+") || body.first == UInt8(ascii: "-") { body = body.dropFirst() }
        if body.elementsEqual("inf".utf8) || body.elementsEqual("nan".utf8) { return true }
        let exponentIndex = body.firstIndex { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
        let mantissa = body[..<(exponentIndex ?? body.endIndex)]
        let dot = mantissa.firstIndex(of: UInt8(ascii: "."))
        let integer = mantissa[..<(dot ?? mantissa.endIndex)]
        guard digits(integer), integer.count == 1 || integer.first != UInt8(ascii: "0") else { return false }
        if let dot, !digits(mantissa[mantissa.index(after: dot)...]) { return false }
        if let exponentIndex {
            var exponent = body[body.index(after: exponentIndex)...]
            if exponent.first == UInt8(ascii: "+") || exponent.first == UInt8(ascii: "-") { exponent = exponent.dropFirst() }
            guard digits(exponent) else { return false }
        }
        return dot != nil || exponentIndex != nil
    }

    /// Offset or local date-times, local dates, and local times; seconds are optional (TOML 1.1).
    static func isDateTime(_ token: [UInt8]) -> Bool {
        var cursor = 0
        func number(_ width: Int) -> Int? {
            guard cursor + width <= token.count, token[cursor..<cursor + width].allSatisfy({ isDigit($0) }) else { return nil }
            defer { cursor += width }
            return Int(String(decoding: token[cursor..<cursor + width], as: UTF8.self))
        }
        func expect(_ character: Character) -> Bool {
            guard cursor < token.count, token[cursor] == character.asciiValue else { return false }
            cursor += 1
            return true
        }
        func time() -> Bool {
            guard let hour = number(2), hour < 24, expect(":"), let minute = number(2), minute < 60 else { return false }
            if expect(":") {
                guard let second = number(2), second <= 60 else { return false }
                if expect(".") {
                    let start = cursor
                    while cursor < token.count, isDigit(token[cursor]) { cursor += 1 }
                    if cursor == start { return false }
                }
            }
            return true
        }
        if token.count >= 3, token[2] == UInt8(ascii: ":") { return time() && cursor == token.count }
        guard let year = number(4), expect("-"), let month = number(2), (1...12).contains(month), expect("-"), let day = number(2) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...days).contains(day) else { return false }
        if cursor == token.count { return true }
        guard cursor < token.count, [UInt8(ascii: "T"), UInt8(ascii: "t"), 0x20].contains(token[cursor]) else { return false }
        cursor += 1
        guard time() else { return false }
        if cursor == token.count { return true }
        if expect("Z") || expect("z") { return cursor == token.count }
        guard expect("+") || expect("-"), let hours = number(2), hours < 24, expect(":"), let minutes = number(2), minutes < 60 else { return false }
        return cursor == token.count
    }
}

// MARK: - Editor

/// Edits a config file by inserting text, re-parsing after every change so each edit sees the
/// document as it now is. Every operation is additive: existing keys are never changed.
struct ClaudeTOMLEditor {
    private(set) var text: String

    init(text: String) throws {
        self.text = text
        _ = try ClaudeTOMLDocument(text)
    }

    private var newline: String { text.contains("\r\n") ? "\r\n" : "\n" }

    // MARK: Operations

    /// Appends each string not already in the array `table.key`, creating the key or the table as
    /// needed. Returns how many strings were added.
    mutating func mergeStrings(_ values: [String], into key: String, of table: String) throws -> Int {
        var seen = Set<String>()
        var incoming = values.filter { seen.insert($0).inserted }
        guard !incoming.isEmpty else { return 0 }
        let document = try ClaudeTOMLDocument(text)
        switch try editableTable(table, in: document) {
        case .missing:
            appendSection([table], lines: arrayAssignment(key, incoming, indent: ""))
        case .implicit(let node):
            if node.entries[key] != nil { throw ClaudeTOMLError.type("\(table).\(key) is not an array") }
            appendSection([table], lines: arrayAssignment(key, incoming, indent: ""))
        case .header(let node, let headerIndex):
            switch node.entries[key] {
            case nil:
                insertLines(arrayAssignment(key, incoming, indent: document.indentation(ofHeader: headerIndex)), inSectionOf: headerIndex, document: document)
            case .value(.array(let array), let statement?) where document.keyValues[statement].keys == [key]:
                let existing = Set(array.items.compactMap { if case .string(let s) = $0 { return s }; return nil })
                incoming = incoming.filter { !existing.contains($0) }
                guard !incoming.isEmpty else { return 0 }
                append(incoming, to: array, document: document)
            case .value(.array, _), .tableArray:
                throw ClaudeTOMLError.unsupportedLayout("\(table).\(key) is written in a form Crok Desktop cannot extend")
            default:
                throw ClaudeTOMLError.type("\(table).\(key) is not an array")
            }
        }
        return incoming.count
    }

    /// Adds each `key = "value"` whose key the table lacks; the first of repeated keys wins. Returns
    /// how many were added. When the table exists but is not a table, nothing is added (as in the terminal).
    mutating func addMissingStrings(_ pairs: [(key: String, value: String)], to table: String) throws -> Int {
        guard !pairs.isEmpty else { return 0 }
        let document = try ClaudeTOMLDocument(text)
        let target: EditableTable
        do { target = try editableTable(table, in: document) } catch ClaudeTOMLError.type { return 0 }
        var present = Set<String>()
        switch target {
        case .header(let node, _), .implicit(let node): present = Set(node.entries.keys)
        case .missing: break
        }
        var lines: [String] = []
        for pair in pairs where present.insert(pair.key).inserted {
            lines.append("\(Self.key(pair.key)) = \(GrokConfig.quote(pair.value))")
        }
        guard !lines.isEmpty else { return 0 }
        switch target {
        case .missing, .implicit: appendSection([table], lines: lines)
        case .header(_, let headerIndex):
            let indent = document.indentation(ofHeader: headerIndex)
            insertLines(lines.map { indent + $0 }, inSectionOf: headerIndex, document: document)
        }
        return lines.count
    }

    /// Whether `parent.name` exists in any form.
    func contains(_ name: String, in parent: String) throws -> Bool {
        let document = try ClaudeTOMLDocument(text)
        guard case .table(let node)? = document.root.entries[parent] else { return false }
        return node.entries[name] != nil
    }

    /// Adds `[parent.name]` with `lines` unless the parent already has `name`. Returns whether it was added.
    mutating func addTable(_ name: String, in parent: String, lines: [String]) throws -> Bool {
        let document = try ClaudeTOMLDocument(text)
        switch try editableTable(parent, in: document) {
        case .header(let node, _), .implicit(let node):
            if node.entries[name] != nil { return false }
        case .missing: break
        }
        appendSection([parent, name], lines: lines)
        return true
    }

    /// Sets `table.key = true`, replacing a `false`.
    mutating func setTrue(_ key: String, in table: String) throws {
        let document = try ClaudeTOMLDocument(text)
        switch try editableTable(table, in: document) {
        case .missing:
            appendSection([table], lines: ["\(Self.key(key)) = true"])
        case .implicit(let node):
            if node.entries[key] != nil { throw ClaudeTOMLError.unsupportedLayout("\(table).\(key) is a table") }
            appendSection([table], lines: ["\(Self.key(key)) = true"])
        case .header(let node, let headerIndex):
            switch node.entries[key] {
            case nil:
                insertLines([document.indentation(ofHeader: headerIndex) + "\(Self.key(key)) = true"], inSectionOf: headerIndex, document: document)
            case .value(.boolean(true), _):
                return
            case .value(_, let statement?) where document.keyValues[statement].keys == [key]:
                replace(document.keyValues[statement].valueRange, with: "true", document: document)
            default:
                throw ClaudeTOMLError.unsupportedLayout("\(table).\(key) is written in a form Crok Desktop cannot change")
            }
        }
    }

    // MARK: Helpers

    private enum EditableTable {
        case missing
        /// Created only by sub-table headers such as `[table.child]`; a `[table]` section may still be added.
        case implicit(ClaudeTOMLTable)
        case header(ClaudeTOMLTable, headerIndex: Int)
    }

    private func editableTable(_ name: String, in document: ClaudeTOMLDocument) throws -> EditableTable {
        switch document.root.entries[name] {
        case nil: return .missing
        case .table(let node):
            switch node.origin {
            case .header:
                guard let headerIndex = node.headerIndex else { throw ClaudeTOMLError.unsupportedLayout("[\(name)] has no header") }
                return .header(node, headerIndex: headerIndex)
            case .implicit: return .implicit(node)
            default:
                throw ClaudeTOMLError.unsupportedLayout("[\(name)] is written as dotted keys or an inline table")
            }
        case .tableArray, .value:
            throw ClaudeTOMLError.type("[\(name)] is not a table")
        }
    }

    static func key(_ key: String) -> String {
        !key.isEmpty && key.utf8.allSatisfy(ClaudeTOMLParserKey.isBare) ? key : GrokConfig.quote(key)
    }

    /// `key = ["a"]`, or one item per line when there are several.
    private func arrayAssignment(_ key: String, _ values: [String], indent: String) -> [String] {
        if values.count == 1 { return ["\(indent)\(Self.key(key)) = [\(GrokConfig.quote(values[0]))]"] }
        return ["\(indent)\(Self.key(key)) = ["] + values.map { "\(indent)    \(GrokConfig.quote($0))," } + ["\(indent)]"]
    }

    private mutating func splice(_ offset: Int, removing length: Int = 0, _ insertion: String, document: ClaudeTOMLDocument) {
        var bytes = [UInt8](text.utf8)
        let start = document.textOffset(offset, in: text)
        bytes.replaceSubrange(start..<start + length, with: Array(insertion.utf8))
        text = String(decoding: bytes, as: UTF8.self)
    }

    private mutating func replace(_ range: Range<Int>, with replacement: String, document: ClaudeTOMLDocument) {
        splice(range.lowerBound, removing: range.count, replacement, document: document)
    }

    /// Inserts whole lines after the last statement of a `[header]` section.
    private mutating func insertLines(_ lines: [String], inSectionOf headerIndex: Int, document: ClaudeTOMLDocument) {
        let offset = document.sectionEnd(ofHeader: headerIndex)
        let nl = newline
        let needsBreak = offset > 0 && document.bytes[offset - 1] != 0x0A
        splice(offset, (needsBreak ? nl : "") + lines.joined(separator: nl) + nl, document: document)
    }

    /// Appends a new `[path]` section at the end of the file, after a blank line.
    private mutating func appendSection(_ path: [String], lines: [String]) {
        let nl = newline
        var result = text
        // Byte checks: Swift treats "\r\n" as one Character, so `hasSuffix("\n")` misses CRLF endings.
        if !result.isEmpty {
            if result.utf8.last != 0x0A { result += nl }
            let bytes = Array(result.utf8.suffix(4))
            let blankLine = bytes.suffix(2) == [0x0A, 0x0A] || bytes == [0x0D, 0x0A, 0x0D, 0x0A]
            if !blankLine && result.utf8.count > nl.utf8.count { result += nl }
        }
        result += "[" + path.map(Self.key).joined(separator: ".") + "]" + nl + lines.joined(separator: nl) + nl
        text = result
    }

    /// Appends strings to an existing array literal in its own style: inline arrays stay on one line,
    /// multi-line arrays get one item per line at the last item's indentation, keeping any trailing comma.
    private mutating func append(_ values: [String], to array: ClaudeTOMLArray, document: ClaudeTOMLDocument) {
        let bytes = document.bytes
        let quoted = values.map(GrokConfig.quote)
        let nl = newline
        guard let last = array.itemRanges.last else {
            let isMultiline = bytes[array.open..<array.close].contains(0x0A)
            if isMultiline {
                let indent = lineIndentation(before: array.open, in: bytes) + "    "
                splice(array.open + 1, quoted.map { nl + indent + $0 + "," }.joined(), document: document)
            } else {
                replace(array.open..<array.close + 1, with: "[" + quoted.joined(separator: ", ") + "]", document: document)
            }
            return
        }
        // Where the last item's line ends, unless the closing bracket comes first on that line.
        var cursor = array.trailingComma.map { $0 + 1 } ?? last.upperBound
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "#") {
            while cursor < bytes.count, bytes[cursor] != 0x0A { cursor += 1 }
            if cursor > 0, bytes[cursor - 1] == 0x0D { cursor -= 1 }
        }
        let lineBreak = cursor < bytes.count && (bytes[cursor] == 0x0A || bytes[cursor] == 0x0D)
        guard lineBreak, cursor < array.close else {
            // Single-line arrays, or a closing bracket on the last item's line.
            splice(last.upperBound, ", " + quoted.joined(separator: ", "), document: document)
            return
        }
        let indent = itemIndentation(last.lowerBound, in: bytes)
        if array.trailingComma != nil {
            splice(cursor, quoted.map { nl + indent + $0 + "," }.joined(), document: document)
        } else {
            // Insert the new lines first so the comma's offset stays valid.
            splice(cursor, quoted.map { nl + indent + $0 }.joined(separator: ","), document: document)
            splice(last.upperBound, ",", document: document)
        }
    }

    private func lineIndentation(before offset: Int, in bytes: [UInt8]) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        return String(decoding: bytes[start...].prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
    }

    /// The indentation before an item that starts its line, or four spaces past the line's indentation.
    private func itemIndentation(_ offset: Int, in bytes: [UInt8]) -> String {
        var start = offset
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
        if start == 0 || bytes[start - 1] == 0x0A { return String(decoding: bytes[start..<offset], as: UTF8.self) }
        return lineIndentation(before: offset, in: bytes) + "    "
    }
}

/// Bare-key characters, shared by the parser and the editor.
enum ClaudeTOMLParserKey {
    static func isBare(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }
}
