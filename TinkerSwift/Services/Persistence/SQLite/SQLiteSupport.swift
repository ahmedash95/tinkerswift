import Foundation
import SQLite3

enum SQLiteStoreError: Error {
    case sqlite(code: Int32, message: String, sql: String?)
    case invalidData(String)

    var isCorruptionLike: Bool {
        switch self {
        case let .sqlite(code, _, _):
            return code == SQLITE_CORRUPT ||
                code == SQLITE_NOTADB ||
                code == SQLITE_IOERR ||
                code == SQLITE_CANTOPEN
        case .invalidData:
            return true
        }
    }
}

final class SQLiteDatabase {
    let databaseURL: URL
    private let fileManager: FileManager
    private(set) var handle: OpaquePointer?

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
        try open()
    }

    deinit {
        close()
    }

    func reopen() throws {
        close()
        try open()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw SQLiteStoreError.invalidData("Database connection is closed.")
        }

        var errorMessagePointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessagePointer)
        if result != SQLITE_OK {
            let errorMessage = errorMessagePointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            if let errorMessagePointer {
                sqlite3_free(errorMessagePointer)
            }
            throw SQLiteStoreError.sqlite(code: result, message: errorMessage, sql: sql)
        }
    }

    func inTransaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try block()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> SQLitePreparedStatement {
        try SQLitePreparedStatement(database: self, sql: sql)
    }

    func tableExists(_ tableName: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;")
        try statement.bindText(tableName, at: 1)
        return try statement.step() == SQLITE_ROW
    }

    func quickCheck() throws -> Bool {
        let statement = try prepare("PRAGMA quick_check(1);")
        guard try statement.step() == SQLITE_ROW else {
            return false
        }
        return statement.columnText(at: 0) == "ok"
    }

    private func open() throws {
        do {
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SQLiteStoreError.invalidData("Failed to create sqlite directory: \(error.localizedDescription)")
        }

        var rawDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &rawDatabase, flags, nil)
        guard openResult == SQLITE_OK, let rawDatabase else {
            let message = rawDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite open error"
            if let rawDatabase {
                sqlite3_close(rawDatabase)
            }
            throw SQLiteStoreError.sqlite(code: openResult, message: message, sql: nil)
        }

        handle = rawDatabase
    }
}

final class SQLitePreparedStatement {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let database: SQLiteDatabase
    private let sql: String
    private let raw: OpaquePointer

    init(database: SQLiteDatabase, sql: String) throws {
        guard let handle = database.handle else {
            throw SQLiteStoreError.invalidData("Database connection is closed.")
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw SQLiteStoreError.sqlite(code: prepareResult, message: message, sql: sql)
        }

        self.database = database
        self.sql = sql
        raw = statement
    }

    deinit {
        sqlite3_finalize(raw)
    }

    func bindText(_ value: String, at index: Int32) throws {
        try ensure(sqlite3_bind_text(raw, index, value, -1, Self.sqliteTransient) == SQLITE_OK)
    }

    func bindInt(_ value: Int32, at index: Int32) throws {
        try ensure(sqlite3_bind_int(raw, index, value) == SQLITE_OK)
    }

    func bindInt64(_ value: Int64, at index: Int32) throws {
        try ensure(sqlite3_bind_int64(raw, index, value) == SQLITE_OK)
    }

    func bindDouble(_ value: Double, at index: Int32) throws {
        try ensure(sqlite3_bind_double(raw, index, value) == SQLITE_OK)
    }

    func bindNull(at index: Int32) throws {
        try ensure(sqlite3_bind_null(raw, index) == SQLITE_OK)
    }

    func step() throws -> Int32 {
        let result = sqlite3_step(raw)
        if result == SQLITE_ROW || result == SQLITE_DONE {
            return result
        }

        guard let handle = database.handle else {
            throw SQLiteStoreError.invalidData("Database connection is closed.")
        }
        let message = String(cString: sqlite3_errmsg(handle))
        throw SQLiteStoreError.sqlite(code: result, message: message, sql: sql)
    }

    func columnText(at index: Int32) -> String? {
        guard let rawValue = sqlite3_column_text(raw, index) else {
            return nil
        }
        return String(cString: rawValue)
    }

    func columnInt(at index: Int32) -> Int32 {
        sqlite3_column_int(raw, index)
    }

    func columnInt64(at index: Int32) -> Int64 {
        sqlite3_column_int64(raw, index)
    }

    func columnDouble(at index: Int32) -> Double {
        sqlite3_column_double(raw, index)
    }

    func columnType(at index: Int32) -> Int32 {
        sqlite3_column_type(raw, index)
    }

    private func ensure(_ condition: @autoclosure () -> Bool) throws {
        guard condition() else {
            guard let handle = database.handle else {
                throw SQLiteStoreError.invalidData("Database connection is closed.")
            }
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteStoreError.sqlite(code: sqlite3_errcode(handle), message: message, sql: sql)
        }
    }
}
