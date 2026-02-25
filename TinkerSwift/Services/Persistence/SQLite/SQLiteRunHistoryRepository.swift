import Foundation
import SQLite3

final class SQLiteRunHistoryRepository {
    private let database: SQLiteDatabase
    private let formatterWithFractional: ISO8601DateFormatter
    private let formatter: ISO8601DateFormatter

    init(database: SQLiteDatabase) {
        self.database = database

        formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
    }

    func load() throws -> [ProjectRunHistoryItem] {
        let statement = try database.prepare(
            """
            SELECT id, project_id, code, executed_at
            FROM workspace_run_history
            ORDER BY executed_at DESC;
            """
        )

        var history: [ProjectRunHistoryItem] = []

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0),
                  let projectID = statement.columnText(at: 1),
                  let code = statement.columnText(at: 2),
                  let executedAtRaw = statement.columnText(at: 3),
                  let executedAt = parseDate(executedAtRaw)
            else {
                throw SQLiteStoreError.invalidData("workspace_run_history contains invalid rows.")
            }

            guard !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            history.append(
                ProjectRunHistoryItem(
                    id: id,
                    projectID: projectID,
                    code: code,
                    executedAt: executedAt
                )
            )
        }

        return history
    }

    func sync(_ items: [ProjectRunHistoryItem]) throws {
        let sanitizedItems = sanitize(items)
        let newIDs = Set(sanitizedItems.map(\.id))
        let existingIDs = try fetchExistingIDs()

        for item in sanitizedItems {
            try upsert(item)
        }

        for existingID in existingIDs where !newIDs.contains(existingID) {
            let deleteStatement = try database.prepare("DELETE FROM workspace_run_history WHERE id = ?;")
            try deleteStatement.bindText(existingID, at: 1)
            _ = try deleteStatement.step()
        }
    }

    private func fetchExistingIDs() throws -> Set<String> {
        let statement = try database.prepare("SELECT id FROM workspace_run_history;")
        var ids = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0)
            else {
                throw SQLiteStoreError.invalidData("workspace_run_history contains invalid id rows.")
            }
            ids.insert(id)
        }

        return ids
    }

    private func upsert(_ item: ProjectRunHistoryItem) throws {
        let statement = try database.prepare(
            """
            INSERT INTO workspace_run_history (id, project_id, code, executed_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id,
                code = excluded.code,
                executed_at = excluded.executed_at;
            """
        )
        try statement.bindText(item.id, at: 1)
        try statement.bindText(item.projectID, at: 2)
        try statement.bindText(item.code, at: 3)
        try statement.bindText(formatterWithFractional.string(from: item.executedAt), at: 4)
        _ = try statement.step()
    }

    private func sanitize(_ items: [ProjectRunHistoryItem]) -> [ProjectRunHistoryItem] {
        var seen = Set<String>()
        var sanitized: [ProjectRunHistoryItem] = []

        for item in items {
            guard !item.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard seen.insert(item.id).inserted else { continue }
            sanitized.append(item)
        }

        return sanitized
    }

    private func parseDate(_ raw: String) -> Date? {
        if let value = formatterWithFractional.date(from: raw) {
            return value
        }
        return formatter.date(from: raw)
    }
}
