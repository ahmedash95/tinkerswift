import Foundation
import SQLite3

final class SQLiteDraftsRepository {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func load() throws -> [String: String] {
        let statement = try database.prepare("SELECT project_id, code FROM workspace_project_drafts;")
        var drafts: [String: String] = [:]

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let projectID = statement.columnText(at: 0),
                  let code = statement.columnText(at: 1)
            else {
                throw SQLiteStoreError.invalidData("workspace_project_drafts contains invalid rows.")
            }

            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProjectID.isEmpty else { continue }
            drafts[normalizedProjectID] = code
        }

        return drafts
    }

    func sync(_ draftsByProjectID: [String: String]) throws {
        let sanitized = draftsByProjectID.reduce(into: [String: String]()) { result, item in
            let normalizedProjectID = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProjectID.isEmpty else { return }
            result[normalizedProjectID] = item.value
        }

        let newIDs = Set(sanitized.keys)
        let existingIDs = try fetchExistingProjectIDs()

        for (projectID, code) in sanitized {
            try upsert(projectID: projectID, code: code)
        }

        for existingID in existingIDs where !newIDs.contains(existingID) {
            let deleteStatement = try database.prepare("DELETE FROM workspace_project_drafts WHERE project_id = ?;")
            try deleteStatement.bindText(existingID, at: 1)
            _ = try deleteStatement.step()
        }
    }

    private func fetchExistingProjectIDs() throws -> Set<String> {
        let statement = try database.prepare("SELECT project_id FROM workspace_project_drafts;")
        var ids = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0)
            else {
                throw SQLiteStoreError.invalidData("workspace_project_drafts contains invalid id rows.")
            }
            ids.insert(id)
        }

        return ids
    }

    private func upsert(projectID: String, code: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO workspace_project_drafts (project_id, code)
            VALUES (?, ?)
            ON CONFLICT(project_id) DO UPDATE SET code = excluded.code;
            """
        )
        try statement.bindText(projectID, at: 1)
        try statement.bindText(code, at: 2)
        _ = try statement.step()
    }
}
