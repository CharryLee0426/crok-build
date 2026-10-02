import Foundation
import SQLite3

/// A thin wrapper over the system SQLite: Chrome's profile databases are read with it, and the
/// browser keeps its history in one.
final class SQLiteDatabase {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?
    /// SQLite copies bound text and blobs when given this destructor.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    convenience init(url: URL, readOnly: Bool = false) throws {
        try self.init(path: url.path, name: url.lastPathComponent, readOnly: readOnly)
    }

    /// A database that lives only as long as this object.
    static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:", name: "an in-memory database", readOnly: false) }

    private init(path: String, name: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let status = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(handle)
            handle = nil
            throw Failure(message: "Could not open \(name): \(message)")
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    /// Runs one statement with `?` parameters, for writes.
    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try Statement(self, sql)
        try statement.run(values)
    }

    /// Calls `row` for each result row.
    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        let statement = try Statement(self, sql)
        try statement.bind(values)
        while true {
            let status = sqlite3_step(statement.handle)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure() }
            try row(Row(statement: statement.handle))
        }
    }

    /// The first column of the first row, when the query returns one.
    func scalar(_ sql: String, _ values: [Value] = []) throws -> Value? {
        var result: Value?
        let statement = try Statement(self, sql)
        try statement.bind(values)
        if sqlite3_step(statement.handle) == SQLITE_ROW { result = Row(statement: statement.handle).value(0) }
        return result
    }

    /// Whether the table has the column: Chrome adds and renames columns between versions.
    func hasColumn(_ column: String, in table: String) -> Bool {
        var found = false
        try? query("PRAGMA table_info(\(table))") { row in
            if row.text(1) == column { found = true }
        }
        return found
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func failure() -> Failure { Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error") }

    enum Value: Equatable {
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null
    }

    struct Row {
        fileprivate let statement: OpaquePointer?

        func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        func text(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: pointer)
        }

        func blob(_ index: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: pointer, count: count)
        }

        func value(_ index: Int32) -> Value {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: return .integer(integer(index))
            case SQLITE_FLOAT: return .real(real(index))
            case SQLITE_TEXT: return .text(text(index))
            case SQLITE_BLOB: return .blob(blob(index))
            default: return .null
            }
        }
    }

    /// A prepared statement, which a batch of writes reuses.
    final class Statement {
        fileprivate var handle: OpaquePointer?
        private let database: SQLiteDatabase

        init(_ database: SQLiteDatabase, _ sql: String) throws {
            self.database = database
            guard sqlite3_prepare_v2(database.handle, sql, -1, &handle, nil) == SQLITE_OK else { throw database.failure() }
        }

        deinit { sqlite3_finalize(handle) }

        func run(_ values: [Value]) throws {
            try bind(values)
            guard sqlite3_step(handle) == SQLITE_DONE else { throw database.failure() }
        }

        fileprivate func bind(_ values: [Value]) throws {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .integer(let number): status = sqlite3_bind_int64(handle, index, number)
                case .real(let number): status = sqlite3_bind_double(handle, index, number)
                case .text(let text): status = sqlite3_bind_text(handle, index, text, -1, SQLiteDatabase.transient)
                case .blob(let data):
                    // An empty blob has no bytes to point at; a null pointer would bind NULL.
                    status = data.isEmpty ? sqlite3_bind_zeroblob(handle, index, 0)
                        : data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), SQLiteDatabase.transient) }
                case .null: status = sqlite3_bind_null(handle, index)
                }
                guard status == SQLITE_OK else { throw database.failure() }
            }
        }
    }
}
