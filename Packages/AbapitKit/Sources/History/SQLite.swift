import Foundation
import SQLite3

/// A thin wrapper over the system `SQLite3` (plan L7: no third-party code): one connection, statements with their
/// values bound by exact bytes, rows read by exact bytes, and a transaction that rolls back on any error. Not
/// `Sendable`: the `SnapshotStore` actor owns one and is what serializes it.
final class SQLiteDatabase {
    /// SQLite's extended result code and its message.
    struct Failure: Error, Equatable, Sendable {
        let code: Int32
        let message: String
    }

    enum Value: Equatable {
        case integer(Int64)
        case text(String)
        case null
    }

    /// SQLite's `SQLITE_CANTOPEN_SYMLINK`: `SQLITE_OPEN_NOFOLLOW` found a link somewhere in the path. A macro Swift
    /// doesn't import.
    static let cantOpenSymlink = SQLITE_CANTOPEN | (6 << 8)

    private let handle: OpaquePointer

    /// `sqlite3_open_v2(path, flags)`. A busy database is waited on for up to five seconds (another reader, such as the
    /// `sqlite3` command), then refused.
    init(path: String, flags: Int32) throws(Failure) {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let failure = Failure(code: opened.map { sqlite3_extended_errcode($0) } ?? code,
                                  message: opened.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code)))
            sqlite3_close_v2(opened)
            throw failure
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// The last error on this connection.
    private func failure(_ code: Int32) -> Failure {
        Failure(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs `sql`, which may hold several statements (abapit's `executescript`), and returns no rows.
    func execute(_ sql: String) throws(Failure) {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    func prepare(_ sql: String) throws(Failure) -> Statement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure(code)
        }
        return Statement(statement, in: self)
    }

    /// Runs one statement with `values`; no rows.
    func run(_ sql: String, _ values: [Value] = []) throws(Failure) {
        try prepare(sql).run(values)
    }

    /// The rows one statement returns, each read by `row`.
    func rows<T>(_ sql: String, _ values: [Value] = [], _ row: (Row) throws -> T) throws -> [T] {
        try prepare(sql).rows(values, row)
    }

    /// Rows changed by the last INSERT, UPDATE or DELETE (not those a foreign key cascaded to), as Python's `rowcount`.
    var changes: Int { Int(sqlite3_changes64(handle)) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// `PRAGMA user_version`.
    func userVersion() throws -> Int32 {
        try rows("PRAGMA user_version") { Int32(truncatingIfNeeded: $0.integer(0)) }.first ?? 0
    }

    /// `body` inside `BEGIN IMMEDIATE` … `COMMIT`: whole or not at all. Any error in `body` or in the commit rolls back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// `body` inside a read transaction (`BEGIN` … `COMMIT`), so several reads see one state of the file.
    func reading<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        defer { try? execute("COMMIT") }
        return try body()
    }

    final class Statement {
        private let handle: OpaquePointer
        /// Kept so the connection outlives its statements.
        private let database: SQLiteDatabase

        fileprivate init(_ handle: OpaquePointer, in database: SQLiteDatabase) {
            self.handle = handle
            self.database = database
        }

        deinit {
            sqlite3_finalize(handle)
        }

        /// Binds `values` to the statement's parameters, in order. Text is bound by its UTF-8 bytes and their count, so a
        /// NUL inside a string is kept, as Python's `sqlite3` keeps it. SQLite is handed a copy in its own memory, which it
        /// frees (`sqlite3_free`) when done with it, even when the bind fails; `SQLITE_TRANSIENT` would need a bit cast,
        /// which the source scans refuse (`RouteTests.nothingReinterpretsMemory`).
        private func bind(_ values: [Value]) throws(SQLiteDatabase.Failure) {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch value {
                case .integer(let number):
                    code = sqlite3_bind_int64(handle, index, number)
                case .text(let text):
                    let bytes = text.utf8CString  // the UTF-8 bytes and a NUL after them
                    guard let memory = sqlite3_malloc64(sqlite3_uint64(bytes.count)) else { throw Failure(code: SQLITE_NOMEM, message: "out of memory") }
                    let copy = bytes.withUnsafeBufferPointer { memory.initializeMemory(as: CChar.self, from: $0.baseAddress!, count: $0.count) }
                    code = sqlite3_bind_text64(handle, index, copy, sqlite3_uint64(bytes.count - 1), sqlite3_free, UInt8(SQLITE_UTF8))
                case .null:
                    code = sqlite3_bind_null(handle, index)
                }
                guard code == SQLITE_OK else { throw database.failure(code) }
            }
        }

        /// Binds `values` and steps to the end.
        func run(_ values: [Value] = []) throws(SQLiteDatabase.Failure) {
            try bind(values)
            defer { sqlite3_reset(handle) }
            while true {
                let code = sqlite3_step(handle)
                if code == SQLITE_DONE { return }
                guard code == SQLITE_ROW else { throw database.failure(code) }
            }
        }

        func rows<T>(_ values: [Value], _ row: (Row) throws -> T) throws -> [T] {
            try bind(values)
            defer { sqlite3_reset(handle) }
            var found: [T] = []
            while true {
                let code = sqlite3_step(handle)
                if code == SQLITE_DONE { return found }
                guard code == SQLITE_ROW else { throw database.failure(code) }
                found.append(try row(Row(handle: handle)))
            }
        }
    }

    /// The current row of a statement, read by column.
    struct Row {
        fileprivate let handle: OpaquePointer

        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }

        /// The column's text by its bytes (a NUL inside is kept); nil for SQL NULL. Bytes that aren't UTF-8 read as U+FFFD.
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(handle, column) != SQLITE_NULL, let bytes = sqlite3_column_text(handle, column) else { return nil }
            let count = Int(sqlite3_column_bytes(handle, column))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }
}
