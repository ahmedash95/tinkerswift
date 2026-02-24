import Foundation
import SQLite3

final class SQLiteProjectsRepository {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let sanitizer = WorkspaceProjectPersistenceSanitizer()

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func load() throws -> [WorkspaceProject] {
        let statement = try database.prepare("SELECT payload_json FROM workspace_projects;")
        var projects: [WorkspaceProject] = []
        var seenIDs = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let payload = statement.columnText(at: 0),
                  let data = payload.data(using: .utf8),
                  let decoded = try? decoder.decode(WorkspaceProject.self, from: data),
                  let sanitized = sanitizer.sanitize(decoded)
            else {
                throw SQLiteStoreError.invalidData("workspace_projects contains invalid payload rows.")
            }

            guard seenIDs.insert(sanitized.id).inserted else { continue }
            projects.append(sanitized)
        }

        return projects
    }

    func sync(_ projects: [WorkspaceProject]) throws {
        let sanitized = sanitizer.sanitizeDeduplicated(projects)
        let newIDs = Set(sanitized.map(\.id))
        let existingIDs = try fetchExistingIDs()

        for project in sanitized {
            try upsert(project)
        }

        for existingID in existingIDs where !newIDs.contains(existingID) {
            let deleteStatement = try database.prepare("DELETE FROM workspace_projects WHERE id = ?;")
            try deleteStatement.bindText(existingID, at: 1)
            _ = try deleteStatement.step()
        }
    }

    private func fetchExistingIDs() throws -> Set<String> {
        let statement = try database.prepare("SELECT id FROM workspace_projects;")
        var ids = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0)
            else {
                throw SQLiteStoreError.invalidData("workspace_projects contains invalid id rows.")
            }
            ids.insert(id)
        }

        return ids
    }

    private func upsert(_ project: WorkspaceProject) throws {
        guard let data = try? encoder.encode(project),
              let payload = String(data: data, encoding: .utf8)
        else {
            throw SQLiteStoreError.invalidData("Unable to encode workspace project payload.")
        }

        let statement = try database.prepare(
            """
            INSERT INTO workspace_projects (id, payload_json)
            VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json;
            """
        )
        try statement.bindText(project.id, at: 1)
        try statement.bindText(payload, at: 2)
        _ = try statement.step()
    }
}
