import Foundation
import SQLite3

final class SQLiteMetaRepository {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func value(for key: String) throws -> String? {
        let statement = try database.prepare(
            """
            SELECT value FROM workspace_meta WHERE key = ? LIMIT 1;
            """
        )
        try statement.bindText(key, at: 1)

        guard try statement.step() == SQLITE_ROW else {
            return nil
        }

        return statement.columnText(at: 0)
    }

    func setValue(_ value: String, for key: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO workspace_meta (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
        try statement.bindText(key, at: 1)
        try statement.bindText(value, at: 2)
        _ = try statement.step()
    }
}
