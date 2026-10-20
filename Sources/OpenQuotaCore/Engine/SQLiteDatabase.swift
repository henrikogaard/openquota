import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A minimal SQLite connection for app-owned data. Not thread-safe: own it
/// from one actor.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?

    /// `url` nil opens a private in-memory database (tests, no app folder).
    init(url: URL?) throws {
        let path: String
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            path = url.path
        } else {
            path = ":memory:"
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure(description: message)
        }
        if let url {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(statement, database: handle)
    }

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

    var userVersion: Int {
        get { (try? prepare("PRAGMA user_version").first { $0.int(0) }) ?? 0 }
    }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    final class Statement {
        private let statement: OpaquePointer
        private let database: OpaquePointer?

        fileprivate init(_ statement: OpaquePointer, database: OpaquePointer?) {
            self.statement = statement
            self.database = database
        }

        deinit { sqlite3_finalize(statement) }

        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        /// Binds values to ?1, ?2, … in order. Supports String, Int, Double, Bool and nil.
        @discardableResult
        func bind(_ values: [Any?]) -> Statement {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
                case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
                case let value as Double: sqlite3_bind_double(statement, index, value)
                case let value as Bool: sqlite3_bind_int64(statement, index, value ? 1 : 0)
                default: sqlite3_bind_null(statement, index)
                }
            }
            return self
        }

        /// Runs a statement that returns no rows.
        func run(_ values: [Any?] = []) throws {
            bind(values)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw Failure(description: String(cString: sqlite3_errmsg(database)))
            }
        }

        /// Calls `row` for each result row.
        func forEach(_ values: [Any?] = [], _ row: (Statement) throws -> Void) throws {
            bind(values)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else {
                    throw Failure(description: String(cString: sqlite3_errmsg(database)))
                }
                try row(self)
            }
        }

        func first<T>(_ values: [Any?] = [], _ map: (Statement) -> T?) throws -> T? {
            bind(values)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { return map(self) }
            guard result == SQLITE_DONE else {
                throw Failure(description: String(cString: sqlite3_errmsg(database)))
            }
            return nil
        }

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
    }
}
